# Essentials Project

## What this is

A personal data management system replacing Memento Database. Final target:
a Flutter app with a local SQLite backend, running natively on **Windows
desktop** and **Android**, kept in sync via Syncthing (and, for row data,
`sqlite_crdt`/`crdt_sync` — see "Syncing at the Record Level"). This repo
(`C:\Flutter\essentials_app`) is the project root for everything, including
this file and `schema.sql` — see "Project layout" below. (Historically this
file and `schema.sql` lived in a separate OneDrive design folder; moved into
the repo in the "Schema Admin + Migration System" session once `schema_admin`
made a single, in-repo source of truth actually matter — see "Repo move:
CLAUDE.md/schema.sql" further down.)

**Why not a no-code tool:** Obsidian plugins (Bases, DB Folder, etc.),
Grist/NocoDB/Budibase/Visual DB, and Valentina Studio were all evaluated and
rejected — none combine a real SQLite backend + genuine form UI + native
Windows and Android apps with no server dependency. Access + Android was also
rejected (no Access-compatible Android app supports form-plus-relational
selectors). Flutter/SQLite is the only stack that clears all four
requirements.

**Why Flutter specifically** (over .NET MAUI, React Native, Kotlin
Multiplatform): single Dart codebase compiles natively to Windows + Android,
sub-second hot reload, and direct `.db` file access via `sqflite` +
`sqflite_common_ffi` (desktop) — no server, no import/export step, no
proprietary storage format.

**Important distinction from MAUI/Xamarin:** Flutter does NOT map to native
platform UI controls. It draws its entire UI itself via its own rendering
engine (Skia/Impeller) — a Flutter button is Flutter-drawn on both Windows
and Android, not a native Win32/WinUI or native Android control. Windows and
Android just supply the window/surface Flutter paints onto. This is why the
same form/selector code behaves identically on both platforms with no
per-platform UI rework — there's no native control to diverge between them.
Each platform still needs its own native *build* toolchain on the dev
machine, though (see "Toolchain setup" below) — Flutter doesn't eliminate
that, only the native-UI-mapping problem.

## Project layout (two locations, deliberately separate)

- **`C:\Flutter\essentials_app`** — the Flutter project itself, and now
  also the single source of truth for this file and `schema.sql` (moved
  in from the OneDrive design folder in the "Schema Admin + Migration
  System" session — see "Repo move: CLAUDE.md/schema.sql" further down).
  Deliberately **outside OneDrive**. Flutter/Dart builds generate large
  volumes of churning files (`build/`, `.dart_tool/`) that OneDrive's
  continuous sync fights with — this is the same failure mode Mike hit
  repeatedly with .NET MAUI + OneDrive, never resolved reliably, and it's
  not worth re-litigating here. `Essentials.xlsx` and the retired
  `migrate.py` remain in the old OneDrive Essentials folder (historical
  only — see "Files in this folder" below); they were never build inputs,
  so leaving them OneDrive-synced was never a problem the way `CLAUDE.md`/
  `schema.sql` living there was.
- **`C:\Databases\essentials_app`** — where `essentials.db` actually lives.
  **Moved here from the OneDrive folder** (see "Sync architecture" below
  for why) — mirrors the `C:\Flutter` convention, and anticipates other
  SQLite-backed projects following the same pattern later:
  `C:\Databases\<project_name>`.

**`essentials.db` has exactly one Windows copy** (`C:\Databases\essentials_app`)
and is kept in sync with the Android copy via Syncthing — see "Sync
architecture" below. The Dart app reads it via a configurable,
platform-conditional path constant (not hardcoded) rather than bundling a
copy inside the Flutter project. Do not create a second Windows copy for
convenience — two copies of the same database is a drift risk this project
has otherwise been careful to avoid.

## Tools

- **Flutter/Dart** — the target app framework. Compiles the single Dart
  codebase natively to Windows desktop and Android; see "Why Flutter
  specifically" above for why it was chosen over the alternatives evaluated.
- **Claude Chat** (claude.ai-style conversation, in Claude Desktop's Chat
  tab) — planning, schema/design discussions, anything conversational that
  doesn't need file or terminal access. No access to this project's files;
  works from chat history and whatever's pasted in.
- **Claude Code** (Claude Desktop's Code tab, pointed at the relevant
  folder) — hands-on work: running scripts, editing real files, debugging
  actual build/runtime errors, and one-shot commands that complete and exit
  on their own (`flutter build`, `flutter analyze`, `flutter test`,
  `flutter doctor`). Has direct file and terminal access; Chat does not.
  **Cannot run `flutter run`'s interactive hot-reload session** — see
  "Interactive terminal / hot reload constraint" below. See "Working across
  Claude Desktop's Chat and Code tabs" further down for how Chat and Code
  stay in sync (short version: through this file).
- **VS Code** — code editor and Markdown editor (`.dart`, `.sql`, `.py`,
  `CLAUDE.md` itself). Chosen over Notepad++ once Flutter development
  starts, since a real code editor is needed regardless and consolidating
  on one tool beats switching per file type. Also used to initialize Git
  repos via its Source Control panel (see "Version control" below), and —
  once the Flutter/Dart extensions are installed — owns the actual
  hot-reload development loop (see below).
- **Claude Code extension for VS Code** — installed and available, but
  deliberately a *supplement*, not a second primary driver. Desktop's Code
  tab (the running "Flutter Initial Implementation" session) remains the
  one place substantial work, commits, and project history happen. The
  extension's actual value is narrow and specific: inline diffs and
  file/selection @-mentions *inside the same window* as the hot-reload
  session, for quick targeted edits while watching the live app run —
  avoids alt-tabbing to Desktop for small tweaks. It's a third surface
  running Claude Code sessions (alongside Desktop's Chat and Code tabs),
  which reintroduces the same context-fragmentation risk `CLAUDE.md` exists
  to solve — don't let it become a second place where undocumented
  decisions happen. If it's ever used for something substantial rather
  than a quick inline tweak, that decision still needs to land in this
  file like anything else.
- **Letos** (formerly SQLiteStudio) and **DBeaver Community** — SQLite
  database browsing/editing. Letos is the primary: fully free with no
  paywalled tiers, SQLite-specific (not a general-purpose multi-DB tool),
  built-in ERD editor, and WAL-journaling-aware (relevant given the
  Syncthing WAL checkpoint discipline below). DBeaver Community is the
  secondary/cross-check tool — already proven working for verifying the
  first `essentials.db` migration.
  - Letos ERD editor: **Tools > Open ERD Editor** (also available as a
    toolbar icon — pencil + ruler). Less readable at a glance than
    DBeaver's relationship diagram, but table objects are directly editable
    from the sidebar by clicking them on the diagram.

## Procedures

Quick-reference checklists for recurring operational tasks — the *how*,
in order, no rationale. The rationale, decisions, and the session each
was worked out in still live in the narrative sections below (linked from
each checklist); update both if a step ever changes.

### Create a new table

Rare (Mike's own framing: "nearly like creating a new app in
essentials_app") — full writeup and reasoning in "Syncing at the Record
Level" > "Letos/DBeaver workflow going forward".

1. Decide the schema for the new table, including the id scheme:
   `id INTEGER PRIMARY KEY AUTOINCREMENT` for a small reference/lookup
   table; `id INTEGER PRIMARY KEY DEFAULT (...)` for a real
   user-entered/offline-written table, using the exact generator
   expression already in `schema.sql` (search it for `unixepoch` and
   copy from an existing table, e.g. `shipment` — don't retype it):
   ```sql
   id INTEGER PRIMARY KEY DEFAULT (
       CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
       + (abs(random()) % 1000)
   )
   ```
2. Close `essentials_app` on every device (MIKE-CU, MIKE-12R), leaving
   the server running. Not optional caution: `server.dart`'s own comment
   on `schemaStatements` explains why — merging works off whatever table
   names a *connected* client mentions, not an agreed fixed list, so a
   device that already has the new table while still syncing risks a
   broken merge before every copy matches. Force-stop on Android
   specifically (Settings → Apps → essentials_app → Force stop) — the
   battery-optimization exemption means it can otherwise keep syncing in
   the background.
3. In Letos, generate the `CREATE TABLE` statement against MIKE-CU's
   `essentials.db`, appending these four as the last columns, exactly,
   making sure no business column name matches them (or `key` — a known
   `sqlparser` bug silently drops a bare `key` column):
   ```sql
   is_deleted INTEGER DEFAULT 0,
   hlc        TEXT NOT NULL,
   node_id    TEXT NOT NULL,
   modified   TEXT NOT NULL
   ```
4. Execute the `CREATE TABLE` statement in Letos. Do not insert any
   rows — row creation only ever happens through `essentials_app` itself
   (a Letos-inserted row never gets its `hlc`/`node_id`/`modified`
   touched, so it would silently never sync).
5. Add the now-proven-working `CREATE TABLE` statement to `schema.sql`
   (`C:\Flutter\essentials_app\schema.sql`). Running it in Letos first
   (step 4) catches a typo before it's the copy source for every step
   below — from here on, copy from `schema.sql`, not from Letos's editor
   or by retyping.
6. Copy the statement from `schema.sql` and run it on MIKE-12R using
   **SQLite Pro**. Same rule — no row insertion.
7. Copy the statement from `schema.sql` and run it against the server's
   `hub.db` (`C:\Databases\essentials_app\server\hub.db`) using Letos or
   DBeaver. This makes the table available to the running server
   immediately.
8. Copy the statement from `schema.sql` into `server.dart`'s own
   `schemaStatements` list (`essentials_app/server/bin/server.dart`) and
   commit it. Doesn't affect the already-running server —
   `schemaStatements` only ever runs once, the first time `hub.db` itself
   is created — but leaving it out would silently break a future
   from-scratch rebuild of `hub.db`.
9. Reopen `essentials_app` on MIKE-CU then MIKE-12R. Table discovery
   only runs at launch, not live. The server does **not** need
   restarting — step 7 already updated the live `hub.db` directly, and
   step 8 only matters for a future rebuild, not right now.

### Add a column

Additive, safe, and the most common schema change — built into
`essentials_app` itself (Settings → "Add a column"). Full writeup and
reasoning in "Syncing at the Record Level" > "Letos/DBeaver workflow
going forward". Unlike "Create a new table" above, the change has to be
made from *inside* a running `essentials_app`, on whichever device you're
adding it from — so the "close every device first" precaution below
applies to every device except that one, which closes immediately after
instead.

1. Close `essentials_app` on every device except the one you're about to
   use, leaving the server running. Same reason as "Create a new table"
   step 2 — a device that's still connected while schemas don't match
   risks a failed merge.
2. On the device you left open, go to Settings → "Add a column", fill in
   the table/column/type/default, and run it. The screen validates the
   reserved/duplicate-name checks and shows a live DDL preview itself —
   no separate manual check needed here, unlike step 3 of "Create a new
   table".
3. Close `essentials_app` on that same device too, right away — within
   moments of finishing in the screen, not on any kind of timer. There's
   no visible countdown to watch (`SyncService`'s periodic-reconnect timer
   only logs to a debug console, not the running app), so don't try to
   time it; just close it promptly and treat that as done.
4. Add the exact statement — shown in the screen's success dialog,
   copyable — to `schema.sql`. Same reasoning as "Create a new table"
   step 5: this becomes the copy source for every step below.
5. Copy the statement from `schema.sql` and run it on MIKE-12R using
   **SQLite Pro**. Confirm the column is there via SQLite Pro's own
   schema view — that's the same confirmation `essentials_app` would show
   you, without needing to open it on that device.
6. Copy the statement from `schema.sql` and run it against the server's
   `hub.db` (`C:\Databases\essentials_app\server\hub.db`) using Letos or
   DBeaver. Confirm it the same way, via that tool's schema view. This
   makes the column available to the running server immediately.
7. Copy the statement from `schema.sql` into `server.dart`'s own
   `schemaStatements` list (`essentials_app/server/bin/server.dart`) and
   commit it. Doesn't affect the already-running server — only matters
   for a future from-scratch rebuild of `hub.db`.
8. Once steps 5–6 are confirmed on every copy, reopen `essentials_app` on
   every device. Table discovery only runs at launch, not live, so the
   new column won't show up in the grid/form on any device until it's
   restarted there.

## Version control

Git, via VS Code's Source Control panel (not the command line) for
initialization, and **GitHub Desktop** for day-to-day commit review,
push/pull — Mike's existing tool of choice from prior GitHub/Visual Studio
work. Claude Code will also make its own commits directly at logical
checkpoints while working; these show up in GitHub Desktop like any other
commit and are reviewable/revertible the same way.

- Repo: **essentials_app**, private, on GitHub. Local clone at
  `C:\Flutter\essentials_app`. Description: "Essentials project to replace
  Memento Database usage."
- `flutter create`'s generated `.gitignore` excludes `build/` and
  `.dart_tool/` — the churn-causing folders. `*.db` added defensively as
  well, even though `essentials.db` shouldn't ever live in this folder —
  cheap insurance against an accidental local copy getting committed.
- Setup history: repo initialized via VS Code (had to exit Restricted Mode
  first via "Manage Workspace Trust" — VS Code sandboxes newly-opened
  folders by default). A stray `Essentials - Shortcut.lnk` (a File Explorer
  shortcut back to the OneDrive Essentials folder) was accidentally
  committed in the first commit, then moved to `C:\Flutter\` and removed
  from the repo in a second commit — worth knowing if the early Git history
  looks odd. Repo published to GitHub via GitHub Desktop, private.
- `essentials_app\CLAUDE.md` **is** the real file, since the "Schema Admin
  + Migration System" session's repo move — see "Repo move: CLAUDE.md/
  schema.sql" further down for why and when. Before that, it was a one-line
  `@import` pointer to the real file in a separate OneDrive design folder.
  `server/CLAUDE.md` and `schema_admin/CLAUDE.md` are each now a one-line
  `@../CLAUDE.md` pointer back to this file (Claude Code supports `@path`
  imports, expanded at session start) — short relative imports, not
  absolute cross-folder ones, now that everything lives in one repo.

## Repo move: CLAUDE.md/schema.sql — "Schema Admin + Migration System" session

This file and `schema.sql` used to live in a separate OneDrive design
folder (`C:\Users\Mike\OneDrive\Documents\Essentials`), pointed at from
`essentials_app\CLAUDE.md` via a one-line absolute `@import`. Moved into
the repo, as the real files at `C:\Flutter\essentials_app\CLAUDE.md` and
`C:\Flutter\essentials_app\schema.sql`, once `schema_admin` (see
"schema_admin — migration authoring tool" below) made a second project
needing the same context a real, immediate need rather than a hypothetical
— a third absolute cross-folder `@import` pointer was worse than just
moving the source of truth in-repo and letting `server/`/`schema_admin/`
each carry a short relative `@../CLAUDE.md` pointer instead. Confirmed
working (both pointer files resolve, content matches), then the OneDrive
originals were deleted — this repo is now the only copy of either file.
`Essentials.xlsx` and the retired `migrate.py` stayed behind in the
OneDrive folder; they were never build inputs and this move was never
about them.

## Toolchain setup

- **Flutter SDK 3.44.6** installed to `C:\src\flutter`, added to user PATH
  (persists in new terminals).
- **Visual Studio Community 2026** (the stable release — not the Insiders
  prerelease edition, which was initially installed and had to be
  corrected) with the **"Desktop development with C++" workload** (MSVC
  v142 build tools, C++ CMake tools, Windows 10 SDK) — required for
  `flutter build windows` / `flutter run -d windows`. This is a genuinely
  common miss in Flutter Windows setup since the Flutter SDK install alone
  doesn't include it.
- **Android SDK / Android Studio: not yet installed — deliberately
  deferred.** Decision was to get Windows desktop fully verified first, one
  platform at a time, rather than debug both toolchains simultaneously.
  **This needs to happen before any form/data-entry UI development
  starts** — Mike wants Android operational first, since forms are the
  make-or-break piece of the project and should be built/tested against
  both real targets from the start, not retrofitted to Android later.
- **Chrome / web target: not installed, not relevant.** This project has no
  web target; `flutter doctor` will always flag this and it can be ignored.
- **`flutter doctor -v` is the standard way to check all of the above** —
  run it after any toolchain change to confirm what's actually
  resolved vs. still gapped.

**Known recurring flake: VS Code's F5 launch to MIKE-12R (CPH2611) over USB
intermittently fails** — same root cause (a USB-level connection drop, not
a build/signing/app problem), but confirmed across two different failure
stages now, not just one:
- **Install stage:** `adb.exe: failed to install ...: Error launching
  application on CPH2611` or `Error: ADB exited with exit code 1`, right
  after a successful build. First seen during the Settings & Persistence
  Architecture session — the adb `transport_id` for the device changed
  between two `adb devices` calls seconds apart (USB re-enumerated
  mid-session), and a plain manual `adb install -r
  build\app\outputs\flutter-apk\app-debug.apk` immediately succeeded with
  the exact same APK F5 had just failed to push.
- **Debug-connection stage, seen later the same phase:** the APK installs
  and the app actually launches on-device (Flutter engine loads, Impeller
  starts rendering) but `flutter run`/F5 then fails with `Error connecting
  to the service protocol: ... WebSocketChannelException: SocketException:
  The remote computer refused the network connection` — the DDS/VM-service
  port-forward adb sets up for the debug connection didn't come up
  cleanly. No stale `adb forward` entries were the cause (checked via `adb
  forward --list`, empty); the device's `transport_id` had again changed
  since the last check, consistent with the same underlying USB
  instability, just surfacing one step later in the launch sequence.

**Workaround when it hits, either stage:** `adb kill-server` then `adb
start-server` (confirms the device reconnects with a fresh `transport_id`),
then retry F5. For the install-stage variant specifically, a manual `adb
install -r` also works. Don't chase either as an app bug — it's the same
USB connection dropping mid-launch, not code.

**A third variant showed up later the same phase, worse than the first
two: a mid-launch USB drop that killed the app process entirely** (`Lost
connection to device` after the VM service had already connected and the
app was rendering) — no crash, no exception logged app-side, db opened
fine beforehand (confirmed via the `-wal` file being actively written).
Three distinct USB failure modes in one session, one of which
(indirectly, by landing a relaunch in a bad window right as Syncthing was
mid-conflict) contributed to the empty-db-propagation incident above —
enough to stop treating USB as reliable for this device.

**Switched MIKE-12R to wireless adb as a result** — removes USB from the
picture entirely rather than continuing to work around individual
symptoms:
```
adb tcpip 5555                    # while still on USB
adb connect <phone-wifi-ip>:5555  # phone Settings > About > Status, or `adb shell ip addr show wlan0`
```
then physically unplug the USB cable — `adb devices` should show only the
`<ip>:5555` entry afterward (leaving both connected at once confuses VS
Code's device picker). Verified working via a clean `adb install -r` over
the wireless link. **Reverts to USB-only on phone reboot** — `adb tcpip`
has to be re-run over USB again after a reboot; the wireless connection
itself doesn't survive it. Phone and PC must be on the same Wi-Fi network
(both were, at `10.0.0.x` this session).

**Second wireless method found later, USB-free entirely: Android 11+'s
native "Wireless debugging" toggle** (Settings > Developer options >
Wireless debugging), distinct from the `adb tcpip` approach above — no USB
cable needed at any point, including the first connection, but needs a
one-time pairing per PC instead:

1. On the phone, open the Wireless debugging screen itself (not just the
   toggle) and tap **"Pair device with pairing code"** — shows a pairing
   IP:port and a 6-digit code (both one-time/ephemeral, different from the
   IP:port shown on the main screen).
2. On the PC:
   ```
   adb pair <pairing-ip>:<pairing-port> <6-digit-code>
   ```
3. No separate `adb connect` needed — mDNS auto-discovery picked the
   connect endpoint up immediately after a successful pair, `adb devices`
   showing it as `adb-<guid>._adb-tls-connect._tcp`, state `device`.

Verified working end-to-end against MIKE-12R (`CPH2611`, Android 16/API 36)
from a fresh PC-side pairing state — `flutter devices` picked it up as
"CPH2611 (wireless)" right after, no VS Code restart needed (a
Reload Window may be needed if the device picker doesn't refresh on its
own). **Does not survive a phone reboot or Wi-Fi drop** — the pairing
IP:port/code are one-time, so reconnecting after either means going back to
the phone's Wireless debugging screen for a fresh pairing code and
repeating the `adb pair` step; there's no equivalent of the tcpip method's
"just re-run one command over USB" recovery.

### Interactive terminal / hot reload constraint

Claude Code's shell in a Code tab session is **non-interactive** — it runs a
command, captures output, and the command must exit on its own. `flutter
run`'s hot-reload session is an interactive REPL (waits for keypresses: `r`
reload, `R` restart, `q` quit) and cannot run inside Code's shell — stdin
hits EOF and the session tears down, killing the app with it ("Lost
connection to device").

**What Code *can* do:** one-shot commands that complete and exit on their
own — `flutter build windows`, `flutter analyze`, `flutter test`, `flutter
doctor`. It can also build a Windows exe and launch it directly (bypassing
the hot-reload wrapper) to visually confirm a build works, as was done to
verify the initial Windows desktop scaffold.

**What Code cannot do, and what needs VS Code instead:** the actual
day-to-day hot-reload development loop. Fix: install the **Flutter**
extension in VS Code (pulls in the **Dart** extension as a dependency), then
use VS Code's own **Run and Debug** (`F5`) to launch the app — this runs
`flutter run` inside VS Code's own interactive process, fully separate from
Code's shell, with hot reload on save working automatically. Division of
labor going forward: Code edits Dart source and runs one-shot
build/verify commands; the live hot-reload session runs in VS Code,
watching the same files.

## Migration path (where we are in it)

1. ~~Design libraries in `Essentials.xlsx`~~ — Excel Tables + Named Ranges as
   the schema-design intermediary, one sheet per table, FK-style lookup
   columns (`tblX` / `XList` pattern).
2. ~~Generate SQLite schema + migrate `Essentials.xlsx` → `essentials.db`~~
   — done for the first batch of libraries (see below). **The
   Excel/`migrate.py` path itself is now permanently retired** (see "Files
   in this folder" below) — remaining libraries (Device, Inventory, Symbol,
   Time Tracker, MinInput, image libraries) will go directly into
   `essentials.db` (new tables in `schema.sql`, data via CSV import through
   Letos/DBeaver) when they're picked up, not through Excel first.
3. **Build the Flutter app against `essentials.db`** — in progress.
   ~~`flutter create .` scaffold generated~~. ~~Windows desktop build
   verified end-to-end~~ (compiled clean, ran as a standalone window).
   ~~Install VS Code's Flutter/Dart extensions, confirm hot reload~~.
   ~~Android toolchain fully operational, verified on MIKE-12R (OnePlus
   12R) via USB~~ — both platforms now confirmed working end-to-end.
   ~~CRUD foundation built and proven against `domain` (batch 1's first
   table): db layer, `TableConfig`-driven generic list/form screens,
   RESTRICT-aware delete, responsive nav shell~~. ~~Batch 1 complete — all
   ten tables built and verified end-to-end on both Windows and Android
   (CPH2611)~~. ~~Batch 2 complete — all nine tables built, registered, and
   verified on both Windows and Android (CPH2611)~~, including the new
   inline lookup-dropdown editing (see "Real friction surfaced" below) —
   confirmed on-device via APK install, including the null/clear option
   and correct persistence, with Syncthing propagating a Windows-side data
   fix back to the phone within the same session (nice real-world
   confirmation the sync architecture works as documented)~~. ~~Batch 3
   complete — `subscription` (7 FK fields) built, its computed
   `yearly_cost`/`next_date` refreshing live in both grid and form (see
   "Batch 3 session, concluded" below), plus a cross-cutting clickable-link
   feature added for every URL-ish field across all tables, not just
   `subscription`~~. ~~Now starting the `Order`/`OrderItem` parent-child
   pattern~~ — put on hold instead (see "Real-usage findings" below):
   `Order`/`OrderItem` were never migrated into `essentials.db`, and Mike
   shifted to using the app for real, which surfaced the Settings &
   Persistence Architecture phase (table view state, sidebar grouping,
   theme/font/color settings, color picker — six build-order steps, all
   ~~now complete and verified on both platforms~~), then the Table
   Discovery phase (all 19 tables retired onto introspection +
   `field_metadata`, no hand-written `TableConfig` left)~~. `Order`/
   `OrderItem` resumed and built in the "Split-Pane Layout" session — see
   "Parent-child (one-to-many) relationships" and "Split-Pane Layout
   session, concluded" below. ~~Build-verified; Mike's interactive
   verification is next~~ — done, passed on both platforms (see that
   session's write-up). `journal`/`shipment`/`subscription` converted onto
   `orders`/`order_items`' `id` scheme in the "ID Primary Key Conversion"
   session — see "id convention changed" and "ID Primary Key Conversion
   session, concluded" below, including a real Syncthing empty-db-propagation
   incident (a second occurrence of the one already documented under "Sync
   architecture") hit and recovered mid-session.

This is **risk-first prototyping**: validate technical unknowns (FK
enforcement, form+selector UI, sync safety) before investing in full build-out.
A Flutter prototype has already validated core SQLite relational behavior:
FK enforcement, RESTRICT constraints, join queries, dropdown selectors
storing integer IDs.

## Files in the old OneDrive design folder (`Essentials.xlsx`, retired `migrate.py`)

`C:\Users\Mike\OneDrive\Documents\Essentials` still holds `Essentials.xlsx`
and the retired `migrate.py` — neither was a build input, so the repo move
(see "Repo move: CLAUDE.md/schema.sql" above) never touched them. `schema.sql`
itself moved to the repo root (`C:\Flutter\essentials_app\schema.sql`) —
still SQLite DDL, every table has a surrogate `id INTEGER PRIMARY KEY
AUTOINCREMENT` (or, for tables created since the "Split-Pane Layout"
session, the timestamp+random `id` scheme — see "New-table conventions"),
the workbook's Name-style columns are `UNIQUE` text, never the PK, and all
FKs are `ON DELETE RESTRICT` by default (see "Parent-child relationships"
below for the deliberate exception). Still actively maintained — new
tables/columns added directly here, not via the old Excel-first workflow.

- `Essentials.xlsx` — **retired, permanently.** Was the design
  intermediary; is no longer the source of truth for anything.
  `essentials.db` is authoritative going forward. If data ever needs
  importing again, the deliberate path is CSV → Letos/DBeaver, not a
  return to the workbook/migration workflow.
- ~~`migrate.py`~~ — **retired, permanently, alongside `Essentials.xlsx`.**
  Historical record only: read `Essentials.xlsx` and populated
  `essentials.db` fresh from `schema.sql` on every run (full rebuild, not
  incremental) — this is how the db was originally built and how batches
  1-3's tables originally got their real data. Not an active workflow.
  Kept here, struck through, so nothing in this file's history is a
  mystery later. (For the record: `DB_PATH` pointed to
  `C:\Databases\essentials_app\essentials.db`, required a raw string —
  `r"C:\Databases\essentials_app\essentials.db"` — since a plain
  `"C:\D..."` throws a `SyntaxWarning` on the invalid `\D` escape; also
  reset `journal_mode` back off WAL on every run, requiring a manual
  `PRAGMA journal_mode=WAL;` after each one.)

`essentials.db` itself no longer lives in this folder — see "Project
layout" above and "Sync architecture" below.

## Schema so far

Lookup tables: `domain`, `priority`, `gender`, `status`, `quality`,
`condition`, `unit`, `importance`, `disposition`, `time_frame`, `class`,
`category` (FK → `class`), `account_type`.

Entity tables: `account` (FK → `account_type`, `domain`), `supplier`,
`shipper`, `person` (FK → `gender`), `shipment` (FK → `supplier`, `domain`,
`shipper`), `subscription` (FK → `domain`, `person`, `class`, `time_frame`,
`account`, `importance`, `disposition`), `journal` (FK → `status`, `person`,
`domain`), `orders` (FK → `supplier`, `RESTRICT`), `order_items` (FK →
`orders`, `CASCADE` — see "Parent-child (one-to-many) relationships" below).

**`subscription_computed`** is a VIEW, not a table — `yearly_cost` and
`next_date` are deliberately **not stored**; they're computed at query time
from `cost` / `start_date` / `time_frame.multiplier` so they can never go
stale. The Flutter app should query this view (or replicate its logic in
Dart) rather than storing those two values anywhere.

**`orders`/`order_items`' `id` column is a new convention, different from
every table before them** — see "New-table conventions" below. **Extended to
`journal`/`shipment`/`subscription` in the "ID Primary Key Conversion"
session** — see that section for the rebuild write-up. `domain`, `priority`,
`gender`, `status`, `quality`, `condition`, `unit`, `importance`,
`disposition`, `time_frame`, `class`, `category`, `account_type`, `account`,
`supplier`, `shipper`, `person` still use the original `AUTOINCREMENT`
scheme — no plan to convert them (they're lookup tables, not offline-write
targets the way entity tables are).

## Build sequence (Flutter forms/data-entry UI)

Deliberately sequenced easiest-to-hardest so the underlying pattern is
learned once, on low-stakes tables, before layering on complexity —
not because the tables differ in how they're built, but so Mike is
comfortable with the tooling and pattern before the stakes (real,
already-populated data with several FK selectors) go up.

**Architecture decision made for this phase:** one config-driven, reusable
CRUD screen pair — not 19 hand-built near-duplicate screens. A Dart
`TableConfig` (table name, field list: name/type/label, and for lookup
fields, which table they reference) drives one generic list screen and one
generic form screen. Batch 1 tables prove the base pattern with a
lookup-free config; batch 2 just adds the lookup-field variant to the same
config shape; by `subscription` (7 FK fields), it's a longer config, not a
new pattern.

**Navigation, built out during batch 1** since it's the first point there's
enough content to need one: responsive layout — `NavigationRail` on Windows
desktop, `Drawer` on Android, same 19-table list, switched via
`LayoutBuilder` rather than two separate implementations. Concrete
demonstration of "one codebase, no native control mapping" actually paying
off, not just an abstract claim from "What this is" above.

**List view is a real data grid (TrinaGrid), not a `ListView`/`ListTile`
list.** Mike's ask, modeled on Memento Database's table view: every field
as its own column, not just the display column. A hand-rolled
`Row`/`Column` grid was tried first and kept hitting problems a real grid
widget already solves (frozen header staying horizontally synced with a
scrolling body, resizable columns, frozen/pinned columns) — swapped to
[TrinaGrid](https://github.com/doonfrs/trina_grid) (`trina_grid` package,
the maintained fork of the now-unmaintained PlutoGrid; if evaluating this
again later, check no *further* fork has since superseded it the same
way). `id` is a structurally read-only (no edit affordance at all, not
just visually disabled), left-frozen column in both the grid and the
form. Interaction model is TrinaGrid's own native one, not the original
hand-rolled spec: single click selects a cell, a second click or
double-click enters inline edit, `Active` is a live checkbox via a custom
cell renderer, and opening the full form / deleting are explicit
pencil/trash icons in a right-frozen actions column (TrinaGrid's own
double-click already owns inline editing, so double-tap couldn't also
mean "open the form" without the two racing). Column reordering via drag
came free with the library. ~~**Known gap:** column widths/order/frozen
state don't persist across app restarts yet — only the row data does
(real SQLite). Needs its own design pass (likely a small settings table
or similar) before it matters much beyond `domain`.~~ **Done** — see
"1. Table view persistence" under "Real-usage findings" below for the
design, and the "Debugging session" at the end of this file for two
persistence bugs (a dropped-save race, then a `sqlite_crdt` upsert
gotcha) plus generalizing this to the `id`/actions columns too, found
fixing it against real usage.

**Delete handling, designed into the template from batch 1, not bolted on
later:** every batch-1/2 table is a lookup that later batches reference via
`ON DELETE RESTRICT`. Deleting a row still in use elsewhere throws a SQLite
constraint error — the generic template's delete action must catch that and
show something like "Can't delete — still in use by other records," not
crash or surface a raw SQLite error string.

**Upgraded, "Split-Pane Layout" session: checked *before* the confirm
dialog, not just caught after.** The original design above only caught the
constraint error after the user already clicked "Delete" on a plain
"Delete X? Cancel/Delete" dialog — which implies deletion might succeed,
when a `RESTRICT` reference elsewhere means it structurally can't. Found
by Mike deleting a `supplier` still referenced by `shipment`/`orders`.
`GenericDao.findBlockingReferences(id)` now scans every other real
table's `PRAGMA foreign_key_list` for a non-`CASCADE` FK pointing at this
table, checks whether any row actually references this id, and (applies
generically, not just to `supplier`) `GenericListScreen._delete` shows an
informational "Can't delete — still referenced by X, Y" dialog (dismiss
only, no Cancel/Delete choice) instead of the misleading confirm dialog
when blocked. `CASCADE` FKs are excluded from the check (expected to
cascade, not block) — `order_items` never appears as a blocker for
`orders`. The original post-delete `StillInUseException` catch stays too,
as a defensive fallback for a same-instant race (e.g. another device
syncing in a new reference between the check and the delete).

**Batch 1 — no lookups, proves the base template + navigation:** ~~`domain`,
`priority`, `gender`, `status`, `quality`, `condition`, `unit`, `importance`,
`disposition`, `class` — all ten built, registered in `registeredTables`,
and verified end-to-end (add/edit/delete, inline cell edits) on both
Windows and Android (CPH2611).~~ **Batch 1 complete.** Eight of the ten
share `domain`'s exact shape via a `_lookupConfig()` helper in
`lib/config/table_configs.dart`; `unit` is the one exception
(`abbreviation`/`definition` instead of `description`). Every one of them
has an `active INTEGER NOT NULL DEFAULT 1` column in schema.sql — every
`_lookupConfig()`-built config already sets `defaultValue: true` on that
`FieldConfig` (the form always writes an explicit value on insert, so an
omitted default silently saves as inactive instead of falling through to
the SQL default — hit this exact bug on `domain` first, fixed by adding
`FieldConfig.defaultValue`, then handled correctly for the rest via the
shared helper).

**Side nav is a hand-rolled scrollable rail, not Flutter's
`NavigationRail`,** on wide layouts. `NavigationRail` uses `Expanded`
internally and needs bounded height, so it can't be wrapped in a
scrollable and just overflows once destinations exceed the window's
height — became a real problem at 10 batch-1 tables, well before the
full 19. `lib/screens/home_shell.dart`'s `_railItem()` is a plain
`ListView` of icon+label items instead, visually similar but properly
scrollable. The Android `Drawer` was unaffected (already `ListView`-based).

**Known toolchain quirk (Windows build):** `permission_handler_windows`
(pulled in transitively for the Android-only `MANAGE_EXTERNAL_STORAGE`
check) fails to compile under the installed VS 18 / MSVC 14.51 toolchain
— `<experimental/coroutine>` is now a hard `static_assert` error, not just
a deprecation warning. Fixed via `add_definitions
(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)` in
`windows/CMakeLists.txt` (project-level, so it's not lost on `pub get`).
Also needed: **Windows Developer Mode** enabled (Settings > System >
For developers) — required for the symlink support Flutter's plugin
build uses; without it, both `pub get`'s plugin step and `flutter build
windows` fail. Both already resolved on this machine; noting here in case
of a fresh setup.

**Known gap, not yet addressed:** field defaults (`active`, `position`,
`color`, etc.) are hardcoded as compile-time `defaultValue` constants in
`table_configs.dart`. Mike wants these to eventually be user-editable app
settings instead, so a default can change without a recompile — flagged
explicitly, not yet designed. Worth solving before too many more configs
accumulate hardcoded defaults the same way.

**Batch 2 — same table > form topology, introduces the lookup-field
pattern.** ~~`person` (FK → `gender`), `category` (FK → `class`),
`time_frame` (FK → `unit`), `account_type`, `account` (FK → `account_type`,
`domain`), `supplier`, `shipper` (no FK on either — same shape as
`supplier`; wasn't in the original plan, added here since it's a real
table in the schema that needs a screen too), `shipment` (FK → `supplier`,
`domain`, `shipper`), `journal` (FK → `status`, `person`, `domain`) — all
nine built, registered in `registeredTables`, and verified end-to-end
(including inline cell edits and the edit form re-populating an existing
lookup value correctly) on Windows against the real, already-populated
data (`person`: 4 rows, `journal`: 298 rows, etc.)~~. **Batch 2 complete.**

**Real friction surfaced, as expected — the grid didn't originally know
how to show *or* edit a lookup field at all.** `GenericListScreen` was
built in the CRUD-foundation session against `domain` alone, before
`FieldConfig.lookup` had ever been exercised — the form screen already
handled it (dropdown, built for this from the start), but the *grid* just
rendered whatever raw value was in the column, which for a lookup field is
the numeric FK id (e.g. `3`), not something a person reads. Two passes to
get this right:

1. First pass made lookup columns read-only, resolving the id to display
   text via a per-field id → text map fetched alongside the row data
   (`gender_id: {1: 'male', 2: 'female', ...}`). One related bug caught in
   the same pass: the actions column's edit/delete handlers used to
   reconstruct the row passed to the form by reading straight back out of
   the grid's own `TrinaRow` cells — wrong once a lookup cell holds
   resolved *display* text instead of the id the form's dropdown needs.
   Fixed by looking the row up by `id` in the original (unresolved) row
   list instead.
2. Mike flagged that read-only wasn't good enough — lookup fields should
   edit inline like everything else, not force a trip to the full form.
   Replaced the read-only column with `TrinaColumnType.select<int?>`,
   keyed on the **ids themselves** (not the referenced rows) so the
   stored/edited cell value never diverges from the underlying integer FK
   column — `TrinaColumn.formatter` (independent of column type) turns
   that id back into display text for the cell's own rendering, while the
   select column's `itemToString` labels each id inside the dropdown
   popup. Optional lookups get a `null` entry in `items` for "clear this
   field"; required ones (e.g. `time_frame.unit_id`) don't, matching the
   form's own required-field behavior.

   This surfaced a real environment gap: `TrinaColumnType.select`'s popup
   renders through **shadcn_ui**, which throws (`ShadTheme.of() called
   with a context that does not contain a ShadTheme`) without a
   `ShadTheme` ancestor somewhere above it in the widget tree — the
   dropdown silently opened as a blank grey box instead of a menu, no
   error visible in the release-mode UI (had to run via `flutter run`,
   not the standalone exe, to see the stack trace in console output).
   `shadcn_ui` was already present transitively (pulled in by
   `trina_grid`) but nothing in the app ever provided the theme it
   expects. Fixed by adding `shadcn_ui` as a **direct** dependency (pinned
   to match what `trina_grid` already resolves to — `^0.43.4` — so this
   doesn't independently drag in a second, possibly-incompatible version)
   and wrapping `MaterialApp` in `main.dart` with a `builder:` that
   provides `ShadTheme(data: ShadThemeData(...))` app-wide. Worth knowing
   for any future TrinaGrid popup-style column (date pickers, multi-select,
   etc.) — they likely have the same shadcn_ui dependency.

**Batch 3 — `subscription`:** ~~7 FK fields (`domain`, `person`, `class`,
`time_frame`, `account`, `importance`, `disposition`) plus the
`subscription_computed` view (`yearly_cost`/`next_date` display correctly
as query-time values, not stored ones — see "Schema so far" above)~~.
**Batch 3 complete.** The config-driven pattern from batches 1-2 turned out
to be exactly enough — no new architecture, just a longer config, with two
new `TableConfig`/`FieldConfig` primitives added specifically for the
computed columns: `TableConfig.readSource` (query a view instead of the
table for reads; writes still target the table) and `FieldConfig.readOnly`
(never editable, never written). See "Batch 3 session, concluded" below
for the two computed-field staleness bugs this surfaced and how they were
fixed, plus two cross-cutting features that landed in the same session:
clickable link fields (every `*link*`/`hyperlink` column, not just
`subscription`'s) and a debug-only crash fix in the lookup dropdown.

**After `subscription`:** the plan had been the `Order`/`OrderItem`
parent-child pattern (see below) — but see "Real-usage findings" next:
that's on hold, `Order`/`OrderItem` were never actually migrated into
`essentials.db`, and Mike's shifted to using the app for real instead.

## Real-usage findings — functional requirements, shaped with Chat (current phase)

**Order/OrderItem is on hold.** Nothing to build against — `Order`/
`OrderItem` haven't been migrated into `essentials.db` yet, so that
parent-child work (see below) can't start regardless. Instead, Mike is
using the app for real, day-to-day, on both Windows and Android, to find
what's actually missing before writing more table configs. Mike brought a
prioritized requirements list (kept in Obsidian, outside this project's
folders) to a Chat session; the items below are the result of working
through it. **This is a spec, ready for Code** — not an open discussion
anymore, for the items marked resolved below.

### Governing rule (settles most of what follows)

Every piece of persisted UI/config state falls into exactly one of two
buckets — decide which bucket a *new* one belongs in using this test:
would Mike be annoyed if it *didn't* match across devices, or annoyed if
it *did*?

- **Shared** — organizational/policy choices, same regardless of which
  device: theme, font family/size/color, background color, field display
  labels and defaults, which table belongs to which sidebar group.
  Lives in `essentials.db`, rides the existing Syncthing pipe, no new sync
  engineering needed.
- **Per-device** — facts about how something currently looks/behaves on
  *this* screen: column widths/order/sort/filter/frozen/visible state,
  which sidebar groups are currently expanded/collapsed. **Also lives in
  `essentials.db`**, not a separate local-storage mechanism (`shared_preferences`
  was considered and deliberately rejected — see "Per-device state" below)
  — distinguished from shared rows purely by an added `device_id` column.

**`device_id`:** the real OS-reported hostname (`MIKE-LP`, `MIKE-CU`,
`MIKE-WP`, `MIKE-12R`), queried live from the device at runtime — not a
manually-assigned identifier. This is a personal, non-corporate deployment;
querying the OS directly for its own hostname is the correct approach here
and needs no abstraction beyond that.

**Implementation split, discovered at build time (`lib/util/device_id.dart`):**
Windows has a real hostname reachable from Dart (`Platform.localHostname`,
via `dart:io` — no platform channel needed). Android has no equivalent —
`Platform.localHostname` there resolves to a meaningless generic value, not
the user-facing device name (`MIKE-12R`) shown in Settings > About phone /
Bluetooth. Android goes through a small `MethodChannel`
(`essentials_app/device_id`) into `MainActivity.kt`, reading
`Settings.Global.DEVICE_NAME` — this is the same user-configurable name
Mike already set to `MIKE-12R` to match the Windows naming convention, just
not reachable from Dart directly. Resolved once per app run and cached
(device identity can't change mid-session).

### 1. Table view persistence — per-device, resolved

All of it — column widths, order, sort, filter, frozen state, visibility —
is per-device. No exceptions; Mike confirmed sort/filter should NOT be
shared either, despite that being a closer call than the rest.

**Schema (proposed, ready for Code to refine at implementation time):**
```sql
CREATE TABLE table_column_settings (
    table_name    TEXT NOT NULL,
    device_id     TEXT NOT NULL,
    column_name   TEXT NOT NULL,
    width         REAL,
    display_order INTEGER,
    visible       INTEGER NOT NULL DEFAULT 1,
    frozen        TEXT,  -- NULL, 'left', or 'right'
    PRIMARY KEY (table_name, device_id, column_name)
);

CREATE TABLE table_view_settings (
    table_name     TEXT NOT NULL,
    device_id      TEXT NOT NULL,
    sort_column    TEXT,
    sort_direction TEXT,  -- 'asc' or 'desc'
    filter_json    TEXT,  -- structure TBD at implementation time
    PRIMARY KEY (table_name, device_id)
);
```
One row per column per table per device — not a JSON blob. Deliberately
rejected a blob (originally proposed, Mike pushed back) in favor of this
shape specifically because it's fully inspectable in Letos/DBeaver with no
tooling beyond what's already used daily, and because it generalizes
cleanly toward Mike's stated long-term direction: when a table someday
gets added dynamically (see "Long-term direction" below) rather than
compiled into `table_configs.dart`, its per-device view state can
accumulate into these same tables via the exact same mechanism, with zero
schema change needed specifically for that table.

**Tradeoff, accepted knowingly:** resizing/reordering a column is now a
small write to the synced `essentials.db` rather than a local file —
more frequent WAL activity than a blob or local-prefs approach would
generate. Debounce actual writes (on drag-release, not per-frame) rather
than treating this as a blocker. For two devices and occasional manual
adjustment, not a real problem.

**Restore Defaults button:** per-table-view button, resets everything in
`table_column_settings`/`table_view_settings` for that table+device back
to what `TableConfig` declares (schema column order, no sort/filter, no
hidden/frozen columns — note the default frozen state, e.g. `id` staying
left-frozen, is a `TableConfig` decision, not something TrinaGrid ships
with out of the box, so "defaults" means "what `TableConfig` says," not
"TrinaGrid's factory settings"). Does not touch theme/font/color — those
live in a structurally separate table (`app_settings` below), so this
button can't reach them even by mistake.

### 2. Settings methodology — resolved

Two tables, both in `essentials.db`:

```sql
CREATE TABLE app_settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);
```
Shared, flexible key-value — `theme_name`, `font_family`, `font_color`,
`background_color`. New settings don't require a schema migration to add.

```sql
CREATE TABLE device_settings (
    device_id TEXT NOT NULL,
    key       TEXT NOT NULL,
    value     TEXT,
    PRIMARY KEY (device_id, key)
);
```
Per-device equivalent — currently just `font_size`, the one setting where
shared didn't make sense (real DPI/screen-size differences between Windows
desktop and an Android phone).

**Theme override model:** `app_settings.theme_name` selects a base preset
supplying default values for font family, font size, font color, and
background color. An explicit value for any one of those four in
`app_settings`/`device_settings` overrides what the active theme would
otherwise supply for that specific attribute — a base-plus-override merge,
symmetric across all four (font family/size/color, background color), not
an all-or-nothing switch.

### 3. Field-level policy metadata — resolved, new this session

Distinct from `TableConfig`'s *structural* half (field exists, SQL type,
FK target — that has to match `schema.sql` and is a separate, larger,
deliberately-deferred problem, see "Long-term direction" below). The
*policy* half — display label, insert default, which lookup column to
show, `isLink` — is ready to move to runtime now:

```sql
CREATE TABLE field_metadata (
    table_name           TEXT NOT NULL,
    field_name            TEXT NOT NULL,
    display_label         TEXT,
    default_value          TEXT,
    lookup_display_column TEXT,
    is_link                INTEGER,
    PRIMARY KEY (table_name, field_name)
);
```
A value present here overrides the compiled Dart default in
`table_configs.dart`; absence falls back to what's hardcoded now. Same
override pattern as Theme vs. Font/Color above — worth Code recognizing
this as one consistent rule applied twice, not two different mechanisms.
Directly retires the "hardcoded compile-time defaults" gap flagged back in
batch 1.

### 4. Sidebar grouping — resolved

- Group membership (which table belongs to which named group) — **shared**,
  a small relational table, not shoehorned into `app_settings`:
  ```sql
  CREATE TABLE table_group (
      table_name     TEXT PRIMARY KEY,
      group_name     TEXT NOT NULL,
      group_position INTEGER
  );
  ```
- Which groups are currently expanded/collapsed — **per-device**, belongs
  in `device_settings` (e.g. key `sidebar_collapsed:<group_name>`).
- One group per table (single membership), collapsible, drag-and-drop to
  move tables between groups — all per Mike's original spec, unchanged.

### 5. Color picker for color fields — resolved, independent

Popup color picker for existing hex-string color fields (visible today in
`domain`/`class`/etc.). No dependency on anything else in this section —
values stay stored as hex, same as now. Queue whenever convenient; not
tied to the settings-architecture build order below.

### 6. Font/Color/Theme settings screen — resolved

One settings screen, reading/writing `app_settings` + `device_settings`
(font size only) as designed above.

### ~~Long-term direction (in view, not this phase)~~ — done

~~Mike's stated direction: `essentials app` should eventually work more
like Memento Database — add a table via Letos/DBeaver directly against
`essentials.db`, and the app picks it up without a recompile. That's a
real, substantial future project (reading table structure live via SQLite
introspection — `PRAGMA table_info`, `PRAGMA foreign_key_list` — instead
of hand-written `TableConfig`s in Dart) — explicitly not this phase's
problem to solve~~ — **done, in the "Table Discovery phase" session below**:
every table, old and new, now runs through the same introspection +
`field_metadata` process end-to-end, verified on both Windows and Android.
The per-row shape (vs. a blob) this phase deliberately chose for
`table_column_settings`/`field_metadata` paid off exactly as anticipated —
a dynamically-discovered table's settings accumulate the same way with
zero schema change specific to it. One still-flagged-ahead exception,
unchanged from Mike's original note: shared "saved views" across devices
for a specific table (e.g. common saved views on `subscription`) is a
genuinely different, later idea — still not part of the per-device-only
view-state model, still not built.

### Build order (table persistence is the long-term driver)

1. ~~**Per-device state mechanism, built once, generically** — wires into
   `GenericListScreen` a single time, immediately covers all registered
   tables. Everything else here sits on top of this.~~ **Built, awaiting
   Mike's interactive verification** — see "Settings & Persistence
   Architecture session (in progress)" below.
2. ~~**Restore Defaults** — trivial once #1 exists.~~ **Built alongside #1**
   (same session, same checkpoint) — see below.
3. ~~**`app_settings` / `device_settings` / `field_metadata` added to
   `schema.sql`** — even though their first real UI consumer is later in
   this order, add them now rather than retrofitting later, disconnected
   from how the rest of the schema evolved.~~ **Done** — `table_group` added
   alongside the other three (all four were specced together under "Sidebar
   grouping"/"Settings methodology" above; no reason to split the schema
   landing across two steps). Applied directly to the live `essentials.db`
   via `sqlite3` DDL, verified via direct query (correct shape, all four
   empty). No Dart/UI work this step, per plan — first consumer is Step 4
   (`table_group`) and Step 5 (`app_settings`/`device_settings`).
4. ~~**Sidebar grouping** (`table_group` + per-device collapse state).~~
   **Done, verified on both platforms** — see session write-up below.
5. ~~**Font/Color/Theme settings screen** together (shares one UI, same
   override logic).~~ **Built, awaiting Mike's interactive verification**
   — see session write-up below.
6. ~~**Color picker** — independent, slot in whenever.~~ **Done** — see
   session write-up below.

**Working agreement for this phase, unchanged:** friction gets noticed
through real usage, not a test pass Code drives. New items get discussed
with Chat first — to shape scope, settle the shared-vs-per-device question
using the governing rule above — before Code implements. Mike does his own
interactive testing (Windows clicking, Android via VS Code's F5); Code's
job stops at build+verify and handing off (see "Working style" below for
why this replaced Claude driving screenshot/ADB-based testing).

## Parent-child (one-to-many) relationships — done, "Split-Pane Layout" session

**Built and verified** — `orders`/`order_items`, a real split-pane
master-detail UI, plus the two structural risks flagged below when this
was still on hold. See "Split-Pane Layout session, concluded" further down
for the full build write-up. Design rationale kept below since it's still
accurate, not superseded.

Everything migrated into `essentials.db` before this session was flat:
entity tables with lookup-table FKs (e.g. `subscription` → `class`,
`person`, `time_frame`). **None of it tested true parent-child
ownership** — e.g. an `Order` with multiple `OrderItem` rows that only
make sense in relation to their parent. This was a different shape from
anything built or tested before, in two specific ways:

1. **FK convention exception.** The project default is `ON DELETE RESTRICT`
   for essentially every FK (protects lookup tables from being deleted out
   from under something that references them). Parent-child ownership is
   the deliberate exception: deleting the parent (`Order`) should `CASCADE`
   to its children (`OrderItem`), since an orphaned child row is meaningless.
   Don't apply `RESTRICT` here by default/habit — it's wrong for this
   relationship shape specifically.
2. **Form UI pattern is genuinely new.** Every form built so far is one
   record with some dropdown selectors. A parent-child form needs an
   embedded, editable list of child rows inside the parent's own screen —
   add/edit/delete `OrderItem` rows without leaving the `Order` screen. This
   has not been prototyped in Flutter yet (the earlier prototype validated
   FK enforcement/RESTRICT/joins/dropdown selectors — not this). Mike
   considers the forms/data-entry UI the make-or-break piece of the whole
   project — this pattern in particular deserves real design attention, not
   a quick bolt-on.

**Both risks addressed, "Split-Pane Layout" session:** the schema already
carried the `RESTRICT`-vs-`CASCADE` exception (#1) correctly by the time
this session started (`order_items.order_id → orders`, `ON DELETE
CASCADE`, everything else in the schema `RESTRICT`); the embedded
add/edit/delete list (#2) is `OrderSplitPaneScreen`'s items pane, built by
layering small opt-in hooks onto the existing `GenericListScreen`/
`GenericFormScreen` rather than a bespoke implementation. Full write-up
below.

## Known data quirks (carried over from the workbook, not yet fixed at the
source — decide whether to fix in Excel or just handle in code)

- `time_frame.multiplier` is currently month-denominated for the two active
  rows (Monthly=1, Yearly=12). The `yearly` row's `unit` column says
  `"year"` even though its multiplier is actually a **month** count — no
  functional problem today since `subscription_computed` never reads
  `unit_id`, but it will need reconciling before any unit-aware (i.e.
  Hourly/Daily/Weekly/Biweekly) version of the cost/date logic is built.
- `subscription.payment_method_id` resolves against `account.code` (e.g.
  `"CAPONE MC (7072)"`), **not** `account.name`. Don't assume `name` when
  extending this relationship.
- FK text matching during the old Excel migration was **case-insensitive**
  — Excel's `XLOOKUP` matched case-insensitively and the workbook relied on
  that (e.g. `tblDisposition` stored `keep`/`review`/`cancel` lowercase,
  while `SubscriptionTracker.Disposition` used `Keep`/`Review`/`Cancel`).
  Historical now that `migrate.py` is retired, but the data it produced is
  still live in `essentials.db` — worth remembering if odd casing ever
  turns up in `disposition` or elsewhere, that's why.

## Sync architecture (built and verified)

Syncthing / SyncTrayzor between Windows and Android — same setup already
proven working for Mike's Obsidian vault (`C:\Obsidian` <>
`/storage/emulated/0/Documents/Obsidian/PRIMARY`), extended with a second
folder pair for this project.

**Topology: hub-and-spoke, MIKE-CU as the hub.** MIKE-CU knows all three
other devices (MIKE-LP, MIKE-12R, MIKE-WP); each of those three knows only
MIKE-CU, not each other. Deliberately corrected from an earlier mesh setup
where all devices knew each other — confirmed clean as of this check.

**"Introducer" must stay OFF on every device, permanently** — this isn't
just current config, it's load-bearing for the star topology staying a
star. If any device has Introducer enabled on a relationship, it will
automatically propagate its own known devices onto whatever connects to
it, silently rebuilding the mesh. Hit directly: MIKE-CU had Introducer set
on its MIKE-12R relationship (leftover from the old mesh setup), causing
manually-removed devices (MIKE-LP, MIKE-WP) to keep reappearing on
MIKE-12R — documented Syncthing behavior, not a bug. Fixed by unchecking
Introducer on every device's entry for every other device (Windows:
SyncTrayzor's embedded UI may not expose this — use "Open Syncthing's Web
UI" from the tray icon for the full standard interface if it's missing).
If a device ever needs adding to the hub relationship again, add it
manually and deliberately — don't let Introducer auto-propagate it.

**Real config:**
- Folder ID/label: `essentials_app`
- Windows path: `C:\Databases\essentials_app`
- Android path: `/storage/emulated/0/Databases/essentials_app`
- Folder type: Send & Receive on both sides (the actual intended end-state
  — was safe from day one only because the Android app had no data-access
  layer and structurally couldn't write. **That's no longer true** — the
  Android app can now write real CRUD through `sqflite`, verified against
  `domain`. The single-writer-at-a-time discipline below is now a live
  constraint, not a future one: don't edit on both devices in the same
  window without a checkpoint in between until the app automates it (see
  "Still to be built" below).
- Devices already paired from the Obsidian setup — this was adding a
  folder to an existing device relationship, not pairing from scratch

**WAL mode reverting to `delete` is a confirmed, recurring problem — not a
one-off, and not fully explained.** Two independent findings within the
same "Settings & Persistence Architecture" session: Code found
`journal_mode` was `delete` at session start, before any schema change,
reset it to `wal`. Separately, Mike found it `delete` again later the same
session while cleaning up after the `essentials_app` sync conflict below —
timeline suggests it may have reverted **twice**, not once, with no
confirmed trigger either time. `migrate.py` is ruled out (retired,
verified not run). A schema-change-driven cause (`VACUUM`/`page_size`
changes require temporarily leaving WAL) was considered but is undercut by
Code's finding — that occurrence predated any schema change that session.
Android's scoped-storage FUSE layer possibly not fully supporting WAL's
shared-memory requirements was also considered; evidence inconclusive
either way. **Given it's recurred without a known trigger, treat manual
spot-checking as insufficient on its own** — worth Code adding a defensive
`PRAGMA journal_mode=WAL;` check into `database_helper.dart`'s
`onConfigure`, right alongside `PRAGMA foreign_keys = ON`, so the app
self-corrects on every connection rather than relying on someone noticing
in Letos. Doesn't require knowing the cause to be worth doing — cheap,
automatic, and removes the dependency on human memory for something that's
now happened more than once.

**`.stignore` is per-device, NOT synced between devices** — correcting a
wrong claim recorded earlier in this file (previously stated it "is a
regular synced file," confirmed against Syncthing's own documentation to
be false). Each of the four devices maintains its own independent
`.stignore` for a given folder; a pattern added on one has zero effect on
the others. Practical implication: `*-wal`/`*-shm` exclusion (needed for
`essentials_app`) and the Obsidian `workspace.json`/`workspace-mobile.json`
exclusions (pure per-device UI state, shouldn't sync at all — was causing
constant phantom "out of sync" noise across MIKE-12R/MIKE-LP/MIKE-WP until
fixed) both had to be added **on each device individually**. For
maintainability across four devices going forward, consider Syncthing's
`#include` mechanism: an ordinary file that *does* sync normally (e.g.
`shared-ignores.txt`), referenced from each device's local `.stignore` via
one line (`#include shared-ignores.txt`) — edit the shared list once, on
any device, and it propagates everywhere; each device's actual `.stignore`
only ever needs manual editing once, to add that single include line.

**Runbook: `essentials_app` folder stuck in conflict** (hit once during
this session, while Mike was testing on Android at the same time Code was
actively testing on Windows):
- Symptom: SyncTrayzor shows the folder "Out of Sync" with a failed item;
  console log shows something like `moving for conflict: removing item to
  be replaced: ... The process cannot access the file because it is being
  used by another process`.
- Cause: something (Letos, DBeaver, a running Flutter session, or the
  Android app) still had `essentials.db` open/locked on one side while
  Syncthing tried to swap in a conflicting version from the other —
  the single-writer-discipline risk flagged above, actually happening.
  Likely made worse by WAL having silently reverted to `delete` at the
  time (see above) — DELETE mode's constant file churn (a `-journal` file
  created/deleted on every transaction) gives Syncthing far more
  opportunities to catch the database mid-write than WAL's occasional
  updates would.
- Fix: close every possible writer on **both** platforms (Letos/DBeaver/any
  running Flutter session on Windows; force-stop the app on Android via
  Settings → Apps → essentials_app → Force stop), then Rescan the folder.
  Check afterward for a `*.sync-conflict-*.db` file — if one appears,
  compare it against the real copy in Letos before deciding what to keep.
  A leftover `essentials.db-journal` file afterward isn't itself
  dangerous, but don't assume SQLite will clean it up automatically —
  it only does that for a journal matching an actually-incomplete
  transaction; run `PRAGMA integrity_check;` to confirm the main db is
  consistent, then it's safe to delete the journal file manually if it's
  still there.

**Manual checkpoint discipline, until the Dart layer automates it:**
`PRAGMA wal_checkpoint(TRUNCATE)` before relying on the Android copy being
current. What this actually protects against, precisely: the `-wal`/`-shm`
exclusion means Syncthing was never at real corruption risk from those
files — it simply won't touch them. The actual risk without a checkpoint
is staleness: uncommitted changes sit in the local WAL file, invisible to
Syncthing, so the synced copy on the other device silently lags behind
real edits until a checkpoint folds them into the main file.

**Incident: empty db propagated over Syncthing, both copies briefly at
risk — real data recovered, root cause fixed.** Happened during the
Settings & Persistence Architecture phase, right after the adb-server
restart used to fix a flaky F5 connection to MIKE-12R (see "Toolchain
setup" above). Timeline:
1. Something (most likely Syncthing versioning a conflict during the same
   window Mike/Chat were actively reworking the sync topology today) left
   the canonical `essentials.db` path on MIKE-12R briefly *empty* — the
   real file got moved into Syncthing's own `.stversions/` backup folder.
2. Mike relaunched the app (F5) into that gap. `sqflite`'s
   `openDatabase()` does what it always does when nothing exists at a
   path: silently creates a fresh, empty database — no schema, no data,
   just `android_metadata`. The app didn't know anything was wrong because
   nothing *was* wrong from sqflite's point of view; it just did its
   normal job.
3. That empty stub had a newer mtime than Windows' real copy. Syncthing
   (Send & Receive, as designed) propagated it — **from Android to
   Windows**, overwriting the actual master copy at
   `C:\Databases\essentials_app\essentials.db` with the same empty stub.
4. Symptom Mike saw: MIKE-12R showed the splash screen, then an infinite
   spinner — actually two compounding bugs, not one (see the code-fix
   bullet below).

**Recovery:** confirmed via direct `sqlite3` inspection that both the
Windows and Android canonical copies were the same 12,288-byte empty
stub, and that `essentials.db` inside Android's own `.stversions/` folder
was intact (352,256 bytes, `PRAGMA integrity_check` clean, no FK
violations, real row counts including that day's Step 4 test data).
Syncthing was paused on both devices first (Mike, via SyncTrayzor/web UI)
to stop any further propagation before touching anything. That
`.stversions` copy was then restored to **both** the Windows master path
and the Android path directly via `sqlite3`/`adb push` (bypassing
Syncthing entirely), stale `-wal`/`-shm`/`-journal` files from the empty
stub cleaned up on both sides, and each copy independently re-verified
(integrity check + core table row counts) after being written. **Syncthing
remains paused on both devices** — deliberately left for Mike to
re-enable once he's confirmed the app looks right on both platforms with
sync still off, rather than re-enabling it as part of the recovery itself.

**Root cause fixed, not just patched around this one occurrence:**
`lib/db/database_helper.dart`'s `_open()` now throws before ever calling
`openDatabase()` if nothing exists at the resolved path, and again
afterward if a file exists but has no real schema (checked via the
`domain` table) — either way refuses to silently hand back a usable
connection to an empty/bogus db. This is the actual fix: it turns "app
quietly creates garbage, Syncthing quietly spreads it" into a loud,
immediate failure the moment it would happen, before any real data is at
risk. **Separately, and just as load-bearing:** `HomeShell` and
`PermissionGate`'s `FutureBuilder`s were both checking `!snapshot.hasData`
(or `groups == null`) to mean "still loading," which is also true for
"errored" — so the *new* loud `StateError` from the fix above would
previously still have shown as a silent infinite spinner, not a visible
error. Both now check `snapshot.hasError` first. This second fix is why
Mike saw a stuck spinner rather than a crash or error message in the
moment this actually happened — worth remembering as a general pattern
for any future `FutureBuilder` added to this app: always handle
`hasError` explicitly, don't let "no data yet" cover for both cases.

**Still to be built:**
- `PRAGMA wal_checkpoint(TRUNCATE)` before each sync window, from Dart —
  in the app's own lifecycle handling (e.g. on app pause/close), not just
  manually in Letos. **Reasoning changed as of "Syncing at the Record
  Level":** originally this protected sync correctness itself (Syncthing
  copies the whole file, so uncommitted WAL data was invisible to a
  synced copy until checkpointed). Record-level sync reads live via SQL
  and doesn't need this for correctness — confirmed directly, not
  assumed (see that section's "WAL interaction"). Still worth building —
  keeps the `-wal` file from growing unbounded and makes ad-hoc Letos/
  DBeaver inspection and manual backups less surprising — just no longer
  urgent in the way it used to be.
- ~~**New, higher priority given the recurring WAL finding above:** a
  defensive `PRAGMA journal_mode=WAL;` in `onConfigure`, not just manual
  re-checks.~~ Done — `lib/db/database_helper.dart`'s `onConfigure` now
  re-asserts `PRAGMA journal_mode = WAL` on every connection open,
  alongside `PRAGMA foreign_keys = ON`. A no-op when already WAL, so this
  is pure insurance, not a behavior change; doesn't explain *why* it's
  reverted twice, just stops it mattering.
  **Landed broken, then fixed same session:** the first version used
  `db.execute(...)`, which crashed the db open on every Android launch —
  `PRAGMA journal_mode=WAL` returns the resulting mode as a row, unlike
  `PRAGMA foreign_keys` which returns nothing, and Android's
  `SQLiteDatabase.execSQL()` (what sqflite's `execute()` calls into on that
  platform) rejects any statement that returns a result set ("Queries can
  be performed using SQLiteDatabase query or rawQuery methods only").
  Windows (`sqflite_common_ffi`) doesn't share this restriction, so it went
  undetected there. Symptom on MIKE-12R: stuck at the splash screen, plus
  an intermittent "log reader stopped unexpectedly" VS Code debug-connection
  failure on F5 — the process was dying (uncaught `DatabaseException` during
  db open) before the debugger could attach, not a VS Code/toolchain issue.
  Fixed by switching to `db.rawQuery(...)`, which both platforms accept.
  **Worth remembering for any future PRAGMA added here:** check whether it
  returns a row before deciding `execute` vs. `rawQuery` — `execute` only
  works for the Android/sqflite side when the statement returns nothing.
- Single writer at a time (no simultaneous Windows + Android writes) — not
  yet enforceable in code; currently just a discipline Mike has to
  self-impose (see note in "Real config" above).
- ~~`PRAGMA foreign_keys = ON` must be set in `onConfigure`~~ — done in
  `lib/db/database_helper.dart`, confirmed via the `tool/smoke_test.dart`
  connection smoke test.
- ~~`MANAGE_EXTERNAL_STORAGE` ("All files access") permission~~ — built as
  a first-run `PermissionGate` screen (`lib/screens/permission_gate.dart`)
  using `permission_handler`'s `Permission.manageExternalStorage`; granted
  and verified working on MIKE-12R.

If/when photo capture is added (explicitly out of scope for now), BLOB
image storage should live in a **separate table** so browse queries don't
pull image bytes — same Memento-precedent reasoning as before (dedicated
files subfolder, relative paths stored as TEXT, files synced independently
of the DB).

**Second occurrence, "ID Primary Key Conversion" session — same failure
shape, root cause not fully pinned down this time.** Sequence: sync was
paused on both devices for the whole schema-conversion phase (Code working
against the Windows copy directly); Mike tested the converted app on
Windows (added a record to each of `journal`/`shipment`/`subscription`,
confirmed the new id scheme), then unpaused sync on both devices, then
launched the app on MIKE-12R. Result: MIKE-12R's app failed to launch, and
both the Windows master copy and MIKE-12R's own copy of `essentials.db`
ended up as the same 12,288-byte empty (`android_metadata`-only) stub —
Mike's phrase, accurately: "it destroyed the database."

**Diagnosis, this time via direct `adb`/`sqlite3` inspection rather than
guessing:** both copies confirmed byte-identical empty stubs. MIKE-12R's
own `.stversions/` folder (file versioning enabled there, unlike the
Windows-side folder, which has none configured) held an intact
401,408-byte `essentials.db` timestamped ~3 minutes before the stub
appeared — but on the **old**, pre-conversion schema, confirming MIKE-12R
never received this session's schema change before sync was paused; its
last real sync predated this session entirely.

**Recovery:** sync paused first (both devices) before touching anything.
Mike had independently made his own pre-session copy of `essentials.db`
(`C:\Databases\essentials - Copy.db`) — diffed byte-for-byte identical to
Code's own mid-session backup, so trusted as a clean baseline. That copy
was written back to the Windows master path, the three tables'
id-conversion scripts (`essentials_app/migrations/00{1,2,3}_*.sql`)
re-run against it, and the result re-verified (integrity check, FK check,
row counts, byte-for-byte diff against pre-conversion dumps) exactly as
the first time. The corrected Windows copy was then pushed directly to
MIKE-12R via `adb push` (app force-stopped first to release any file
handle) rather than trusting Syncthing to reconcile two different
histories — pulled back and diffed byte-for-byte to confirm the push
landed correctly before ever re-enabling sync. Mike's manual verification
rows from earlier in the session (added before the corruption) were the
one real loss — not recoverable from anywhere checked (Windows'
`.stversions` doesn't exist; MIKE-12R's only had the older, pre-conversion
state) — accepted as low-stakes since they were verification rows, not
real data.

**Not fully explained, unlike the first incident:** the original fix
(`database_helper.dart` throwing before `openDatabase()` if nothing exists
at the resolved path, and again if a file exists but lacks real schema)
was already in place this whole time and should have turned a missing/bad
file into a loud `StateError`, not a silently-created empty stub — yet an
`android_metadata`-only stub appeared again. Leading hypothesis, not
confirmed: a brief zero-byte or partial file left mid-transfer by
Syncthing (the "unpause both devices, then immediately launch the app"
sequence gives exactly this race — sync hadn't necessarily settled before
MIKE-12R's app opened its copy) would pass the Dart-side `File(path)
.exists()` check (a 0-byte file still "exists") while still being
something SQLite would treat as a fresh db to initialize, bypassing the
guard entirely rather than defeating it. **Not yet hardened against** —
worth considering a follow-up check (e.g. reject a resolved path whose
file size is 0, not just missing) if this recurs. **Procedural mitigation
in the meantime:** after unpausing Syncthing, wait for the folder to show
"up to date" with no pending items in SyncTrayzor/the web UI on **both**
devices before launching the app on either — don't launch immediately
after unpausing.

**Worth distinguishing from the above, hit right after recovering from
it:** once both copies were confirmed byte-identical and sync resumed,
opening the (unchanged) app on Windows then Android produced an actual
SyncTrayzor Conflict Resolver dialog for `essentials.db` — this is *not*
a repeat of the incident. Diffed table-by-table, the only difference
between the two conflicting versions was one `device_settings` row
(`MIKE-CU`/`last_active_table`, a purely cosmetic per-device "which table
screen was last open" value) — everything else, every real table,
byte-for-byte identical. Exactly the "Runbook: essentials_app folder stuck
in conflict" scenario above, and exactly the documented single-writer-at-
a-time risk in "Real config" above, working as designed: Syncthing caught
a genuine near-simultaneous write to that one row and asked which to keep
rather than silently picking one. Resolved by choosing the original file
in the dialog; no data at risk either way.

## Syncing at the Record Level — Parts A-D all done and live-verified; open items are operational follow-ups, not remaining test work (see "Open items" at the end of this section)

**Stack, confirmed and built:** `sqlite_crdt` (client-side, wraps
`sqflite`/`sqflite_common_ffi`, tracks changes per-row) + `crdt_sync`
(client network layer, plus its `crdt_sync_server.dart` library — **not a
separate pub package**, despite the name used when this was first
planned; it's a library file inside the `crdt_sync` package itself,
`import 'package:crdt_sync/crdt_sync_server.dart'`). One author's
ecosystem, pure Dart, no cloud, no new DBMS. Motivated directly by the two
real data-loss incidents above on whole-file Syncthing sync.

**Port and address, permanently confirmed: `10.0.0.134:1340`.**
MIKE-CU's IP made permanent via a router-side DHCP reservation on the
HOMExf gateway (survives OS reinstalls). Windows Firewall rule
`essentials_app crdt_sync_server (TCP 1340)` — inbound, TCP 1340 only,
Private+Domain profiles — added after reclassifying the Ethernet
connection from Public to Private (Windows had it wrong; it's the actual
home network). Both required elevated PowerShell, run by Mike.

**`server/` lives inside `essentials_app`** (`essentials_app/server/`),
its own small Dart console project (own `pubspec.yaml`), not a separate
top-level project — keeps a protocol change and its matching client-side
change in the same commit history. Deliberately does **not** use
`crdt_sync_server.dart`'s `listen()` helper — that function hardcodes
`InternetAddress.loopbackIPv4`, unreachable from any other device on the
LAN. Uses `upgrade()` directly (the same per-connection helper `listen()`
calls internally) inside a manually bound
`HttpServer.bind(InternetAddress.anyIPv4, port)`. Started manually
during this session's development (`dart run bin/server.dart`); now
auto-starts for real on login via a Startup-folder shortcut, showing a
system tray icon rather than a taskbar window — see "Open items" below
for the full write-up and the reasoning against a Windows Service/Task
Scheduler.

**Server holds its own separate hub-replica file**
(`C:\Databases\essentials_app\server\hub.db`), not a shared handle to the
real `essentials.db` — decided after discussing where this stood once
MIKE-LP/MIKE-WP eventually join too. MIKE-CU's own Flutter app connects
to the server as a plain network client, exactly like every other
device — no special-cased "the server IS the app" path. This is why: (1)
it's the standard `crdt_sync` hub-and-spoke pattern, generalizing cleanly
to any number of spokes with zero special-casing: adding MIKE-LP/MIKE-WP
later is just "install app, point at hub IP," (2) real-time push works
identically on every device including MIKE-CU's own UI — two independent
OS processes sharing one SQLite file would have no in-process way to
notify each other of writes, (3) it avoids introducing an untested
multi-process file-locking risk into a project that has already been
burned twice by exactly that category of problem (see the two incidents
above). Trade-off accepted knowingly: two files with overlapping content
on MIKE-CU's disk — not the same risk as the old whole-file-copy model,
since this one is kept correct by the CRDT merge protocol automatically,
not by a blind file copy.

**MIKE-LP and MIKE-WP are deliberately being kept OUT of this via
Syncthing entirely** — not deferred, decided against. Only the *server*
needs a stable, known address; clients don't, since they always initiate
outward. Adding either device later should mean: install the app, it
picks up its own `device_id` automatically, connects outward to an
address that's already fixed and already working.

### Part A — standalone prototype, all six required tests resolved

Built as a throwaway `dart create` console project (outside
`essentials_app`, in scratch space, never committed) — two
`sqlite_crdt` databases simulating MIKE-CU/MIKE-12R, a local
`crdt_sync` server, test tables shaped like the real schema (a
RESTRICT-guarded lookup table, the project's id scheme, an
`orders`/`order_items`-shaped CASCADE pair).

- **Basic propagation, offline queuing, row-level LWW: all confirmed
  empirically**, exactly as expected. LWW in particular: A and B each
  edited a *different field* of the same row while mutually disconnected;
  reconnecting converged to one whole row-version winning outright (the
  later HLC), not a merge of both edits — watched it happen, not just
  trusted the docs.
- **RESTRICT/CASCADE do NOT fire through this pathway — a real,
  load-bearing architectural finding, not a test failure.**
  `sqlite_crdt` rewrites every `DELETE` into a soft-delete
  `UPDATE ... SET is_deleted = 1` (confirmed by reading `sql_crdt`'s
  source, then watched happen live). SQLite's own `ON DELETE
  RESTRICT`/`CASCADE` are trigger-based and only fire on a real `DELETE`
  statement, which never happens once writes go through `crdt.execute()`.
  **Resolution, confirmed working in the prototype and now built into
  `GenericDao`:** RESTRICT enforcement moves entirely to the app-level
  pre-check that already existed (`findBlockingReferences`, built in the
  Split-Pane Layout session) — it was never dependent on the DB backstop
  anyway. What's genuinely gone is the same-instant cross-device race
  backstop; accepted as a real but low-probability risk given there's
  only one other real writer (MIKE-12R) today. CASCADE gets an explicit
  app-level replacement: `GenericDao.delete()` now soft-deletes any
  `ON DELETE CASCADE`-referencing child rows in the same transaction as
  the parent, before deleting the parent itself.
- **The project's id scheme (`id INTEGER UNIQUE NOT NULL DEFAULT (...)`,
  deliberately not `PRIMARY KEY`) is structurally incompatible with
  `sqlite_crdt`'s merge — confirmed, and fixed.** `sqlite_crdt`'s
  conflict-resolution target comes from `PRAGMA table_info`'s `pk > 0`,
  not from `UNIQUE`. Without a declared `PRIMARY KEY`, `merge()` builds
  `ON CONFLICT ()` — invalid SQL, thrown and *silently swallowed* by
  `crdt_sync`'s internal try/catch, never surfaced to the caller. A row
  on an affected table simply never arrives on the other device, with no
  visible error anywhere. **Fix, applied to `orders`/`order_items`/
  `journal`/`shipment`/`subscription`:** `id INTEGER PRIMARY KEY
  DEFAULT (...)` — same exact generator expression, still **not**
  `AUTOINCREMENT`, so the original cross-device collision-avoidance
  property (the reason `PRIMARY KEY` was avoided in the first place) is
  fully preserved — only the SQL keyword wrapping the same expression
  changed, confirmed and re-confirmed with Mike before applying it to the
  real database.

### Part B — server built, firewall configured, both verified live

Done exactly as scoped above. Verified end-to-end before Part C started:
server binds to all interfaces (not just loopback), a real network client
reached it at `10.0.0.134:1340`, and its changeset merged cleanly into
the hub, both before and after the Public→Private reclassification and
firewall rule.

### Part C — real `essentials_app` wired onto `sqlite_crdt`

Turned out to be a full data-layer rewrite, not a quick wire-up — worth
knowing for scoping anything like this again. Concretely:

**Migrations applied to the real `essentials.db`** (backed up before
each, tested against a disposable copy first, `integrity_check`/
`foreign_key_check` clean after each — same discipline as the ID Primary
Key Conversion session):
- `004_crdt_tracking_columns.sql` — adds `is_deleted`/`hlc`/`node_id`/
  `modified` to every table that doesn't need a full rebuild (13 lookup
  tables, `account`/`supplier`/`shipper`/`person`, the 6 per-device/
  settings tables, and `android_metadata` — see below for why that one's
  needed at all).
- `005_entity_id_scheme_and_crdt_columns.sql` — rebuilds `shipment`/
  `subscription`/`journal`/`orders`/`order_items` (same table-rebuild
  procedure 001/002/003 used) with the `id` scheme fix above, CRDT
  columns added in the same pass.
- `006_android_metadata_primary_key.sql` — `android_metadata` (sqflite's
  own internal table, holds just `locale`) got CRDT columns from 004 like
  everything else but was never given a `PRIMARY KEY` — it never had one.
  Same broken-`ON CONFLICT ()` failure mode as the id-scheme issue above,
  for the same underlying reason. Fixed by making `locale` itself the
  primary key (always exactly one row in practice, a fine natural key).
  **Found by actually opening the migrated file with a real
  `SqliteCrdt.open()` and watching it fail — not caught by reading SQL.**
- `007_rename_settings_key_column.sql` — `app_settings.key` and
  `device_settings.key` renamed to `setting_key`. **A real bug in
  `sqlite_crdt`'s dependency `sqlparser`**, isolated with a minimal
  reproduction outside this project: `CREATE TABLE t (key TEXT PRIMARY
  KEY, value TEXT)`, run through `sqlite_crdt`'s CREATE-TABLE rewrite
  (which parses the statement via `sqlparser` to append the CRDT
  columns), silently drops the `key` column entirely — and any
  `PRIMARY KEY`/composite-`PRIMARY KEY` constraint referencing it — from
  the reconstructed table. Renaming or quoting `"key"` both fix it;
  renamed for durability rather than relying on remembering to quote it
  forever in every future fresh `CREATE TABLE` of this schema. **Found
  live**, watching the real crdt_sync server's console while the real
  built app connected to it for the first time — the server's own
  `CREATE TABLE app_settings (...)` (via its `onCreate`) is exactly the
  code path that hits this bug; `essentials.db` itself was never affected
  by it directly (its `app_settings`/`device_settings` tables predate
  this session, built via plain SQL, not through `sqlite_crdt`'s parser)
  but needed the same rename so client and server schemas match.

**`essentials_app`'s data layer**, all in one commit after the above:
`DatabaseHelper` now opens a `SqliteCrdt` instead of a raw `Database`
(same defensive file-exists/real-schema pre-checks, now also checking for
the `hlc` column as proof the migration has run). Every DAO in `lib/db/`
rewritten from `sqflite`'s typed query/insert/update/delete API to raw
SQL — `sqlite_crdt` only exposes `query()`/`execute()`, no typed
convenience layer — with `is_deleted = 0` added to every read (soft-
deletes are never actually removed, so an unfiltered read would show
"deleted" rows again). `TableDiscoveryService` now excludes the four
CRDT bookkeeping columns from every derived `TableConfig` — without this
they'd have shown up as live, editable grid columns/form fields on every
table in the app, since this app's whole discovery mechanism builds a
field for every column it sees and there was previously no column-name
filtering, only table-level.

**Two more real bugs, found only by actually running the thing, not by
analyzing or testing in isolation:**
- `GenericDao.insert()` always omits `id` from a new row (never
  user-edited) — and **SQLite's rowid-alias auto-assignment silently
  bypasses a column's own `DEFAULT` clause whenever that column is
  omitted from the INSERT**, confirmed with a throwaway `sqlite3` table,
  not assumed. Without a fix, every new row on the five timestamp+random-
  id tables would have gotten a small sequential id instead — exactly the
  collision-avoidance property the whole scheme exists for, defeated
  silently. Fixed by looking up `id`'s own `DEFAULT` expression via
  `PRAGMA table_info` and injecting it verbatim as a real SQL expression
  (not a bound value) whenever the caller didn't supply an `id` — reuses
  whatever `schema.sql` actually says rather than duplicating the formula
  in Dart.
- `DatabaseHelper.crdt`'s `_crdt ??= await _open()` pattern only
  serializes *sequential* calls. `HomeShell.initState` fires three
  near-simultaneous unawaited callers (`_loadGroups()`,
  `ThemeController.load()`, `SyncService.connect()`); each saw `_crdt ==
  null` and each independently called `_open()`, racing each other's
  connection lifecycle — manifested as a real crash ("Bad state: This
  database has already been closed") the first time the actual built app
  was launched. Fixed by caching the in-flight `Future` itself in a plain
  (non-`async`) getter, so every concurrent caller awaits the one shared
  `Future` instead of each starting their own.
- A softer, non-bug finding worth remembering: a soft-deleted row still
  occupies its `UNIQUE` constraint slot — deleting a `domain` row named
  "Electronics" and later trying to create a new one with the same name
  will fail with a `UNIQUE` violation where it wouldn't have before
  (tombstones aren't real deletes). ~~Not fixed, just documented — a real,
  if likely rare, behavior change from the pre-CRDT app.~~ **Bit again,
  for real this time, in the "Debugging session" below** — not a rare
  business-data collision but `GenericListScreen`'s own
  `saveColumnSettings`, a delete-then-insert maintenance write against
  `table_column_settings` that crashed on the *second* save ever for a
  given table+device. **General rule, now load-bearing:** any code that
  deletes-then-reinserts rows in a `sqlite_crdt`-managed table must
  `INSERT OR REPLACE` (upsert) instead of a plain `INSERT` — `OR REPLACE`
  matches on the unique/primary constraint regardless of `is_deleted` and
  cleanly replaces the tombstoned row, where a plain `INSERT` collides
  with it. `SqliteCrdtHelpers.upsert` (`sql_helpers.dart`) already does
  this for single-row writes; `saveColumnSettings` is the first
  multi-row case and now follows the same pattern by hand.

**Live end-to-end verification, done properly, not assumed:** built the
real Windows exe (`flutter build windows`) and the real debug APK
(`flutter build apk --debug`, confirms `sqlite3_flutter_libs`' native
Android build path specifically — `sqlite_crdt` always opens through
`sqflite_common_ffi`'s FFI factory internally, on *every* platform
including Android, confirmed by reading its source; it has no native-
`sqflite` code path at all, and Android doesn't reliably expose a system
`libsqlite3` for arbitrary `dlopen`, hence the added dependency). Ran the
real server, launched the real built app against it, confirmed a live
network connection via `netstat`, and confirmed the server's `hub.db`
received every real table with row counts matching the client exactly
(`shipment` 25, `subscription` 14, `journal` 299, `orders` 5,
`order_items` 20, `domain` 5, `android_metadata` 1, etc.) with zero
errors in either console — after finding and fixing the three bugs above
via that exact process. Diffed the real `essentials.db`'s full table
list against `server/bin/server.dart`'s schema list to confirm no other
gaps exist beyond the ones already found (only `sqlite_sequence` is
missing there, and that's fine — `sqlite_crdt`'s own `getTables()`
already excludes anything `sqlite_`-prefixed). This is the first real
sync of actual production data through the actual built app.
`flutter analyze` clean, all 52 tests pass (`flutter test
--concurrency=1` — default concurrency causes real `SQLITE_BUSY`/
`LOCKED` contention between test files independently opening the same
real db file in parallel; a test-infra quirk, not a code bug).

### Part D — real MIKE-12R wiring + genuine bidirectional sync, confirmed working

**MIKE-12R wired to the real server, and real bidirectional sync
confirmed over the actual network** (both devices, real hardware, real
`10.0.0.134:1340`) — not simulated. Sequence and findings:

**Wiring MIKE-12R:** its old local copy (pre-migration, purely for UI
exercise, never real synced data) was replaced wholesale with MIKE-CU's
current real, migrated `essentials.db` (`adb push`, force-stop-first,
pulled-back-and-diffed byte-identical after — same discipline as the two
empty-db-propagation recoveries). **A real gotcha, caught before it
caused actual harm:** pushing MIKE-CU's file byte-for-byte also copies
MIKE-CU's `node_id` — meaning MIKE-12R would start up literally claiming
to *be* MIKE-CU as far as the CRDT protocol is concerned. Traced through
what that actually breaks: `crdt_sync`'s handshake asks each peer for its
watermark on rows *not from itself* (`exceptNodeId: crdt.nodeId`); with
both devices sharing an id, the server would think MIKE-12R already has
anything MIKE-CU ever wrote, and would silently never send it — a real,
silent non-propagation bug, not a hypothetical one. Fixed with
`SqliteCrdt.resetNodeId()` — a method that exists in the library
specifically for this situation (its own doc comment: adopting existing
data under a fresh local identity without breaking future sync). It
updates every row's `modified` column to the new id (so future watermark
comparisons are correct) while deliberately leaving `hlc`/`node_id`
alone (those correctly keep recording that MIKE-CU authored the original
data — MIKE-12R didn't create it, and shouldn't claim to). Run once,
locally, against a prepared copy before pushing it to the device — not
something that needs repeating.

**Real bidirectional propagation confirmed, both directions:** a
clearly-labeled test row inserted on MIKE-CU (via the same `crdt.execute()`
path `GenericDao` uses, connected exactly like `SyncService` does)
appeared on MIKE-12R via live push over the real network; deleting it on
MIKE-CU correctly tombstoned it (`is_deleted = 1`) on MIKE-12R too.
Checked by pulling MIKE-12R's actual database file off the device via
`adb pull`, not by trusting the console log alone — and specifically
by pulling the `-wal`/`-shm` files alongside the main `.db`, not just
the main file, since a very recent write can sit in the WAL without
being checkpointed into the main file yet (a real gap in the first
verification pass — the row was genuinely there, just invisible to a
plain single-file pull).

**Real, non-code finding: MIKE-12R's connection is unstable when the
app backgrounds or the screen sleeps.** First live test showed the
WebSocket connecting then dropping abnormally (code 1006) within
seconds, repeatedly — genuinely alarming until isolated properly.
Ruled out one at a time: signal strength excellent (-27 dBm), phone
reaches the gateway cleanly, MIKE-CU reaches the phone cleanly — the
instability was specific to sustaining a connection to MIKE-CU
specifically, and specifically after the screen had been allowed to
sleep or the app had backgrounded. Confirmed by extending MIKE-12R's
screen timeout, keeping it awake and the app foregrounded, and
re-running the exact same test: fully stable, zero drops, both directions
propagated correctly. This matches OnePlus/OPPO's ColorOS, well known
for aggressively killing background network activity for apps not
explicitly exempted from battery optimization — not a bug in the sync
code, not a router/firewall issue. **Still to be done:** whitelist
`essentials_app` from battery optimization on MIKE-12R (Settings →
Battery → essentials_app → allow background activity, exact wording
varies by ColorOS version) before relying on background sync working
reliably day-to-day, since the whole point of this architecture is
real-time sync without the app needing to be open and foregrounded.

**RESTRICT/CASCADE confirmed end-to-end on real, populated entity data
— and a genuinely serious bug caught in the process.** RESTRICT: the
real `GenericDao.findBlockingReferences` correctly detects a real
supplier ("Amazon") blocked by real `shipment`/`orders` rows — run
against real data, real production code, not a reimplementation.

CASCADE: the first real attempt to delete an `orders` row with real
`order_items` **hung indefinitely and timed out after 30 seconds.**
Root cause: `GenericDao.delete()`'s cascade lookup called
`_foreignKeyRefs(crdt, ...)` — the *parent* `SqliteCrdt` object — from
inside `crdt.transaction()`'s own callback. `sql_crdt`'s `transaction()`
doc comment warns about exactly this ("calls to the parent crdt inside a
transaction block will result in a deadlock"), and nothing in the Part A
prototype or the unit test suite happened to exercise this exact path
(the prototype's hand-written cascade test used only `txn.execute()`
calls, never a nested lookup query) — only a real delete against real,
synced data actually hit it. **This would have hung the app solid the
first time anyone deleted an order with items in production**, with no
error, just an unresponsive UI. Fixed by passing the transaction's own
`txn` instead of the parent `crdt` (widened the lookup helper's
parameter type from `SqliteCrdt` to the shared `CrdtApi` interface both
implement, so it accepts either). Re-verified clean after the fix: real
delete, real cascade, propagated correctly to MIKE-12R over the real
network, confirmed by pulling MIKE-12R's actual file (main + `-wal`) off
the device.

**Real off-`HOMExf`-entirely-then-reconnect test: done, core behavior
confirmed, plus one important robustness finding.** Mike took MIKE-12R
off wifi entirely (not just app-level disconnect), added a real journal
entry through the actual app UI while genuinely offline, then turned
wifi back on. Confirmed via the server's own log: the app reconnected
and flushed that write **automatically, with no manual trigger** — no
force-close, no manual reconnect action, exactly the real-world scenario
this was meant to prove. Losing adb (wireless debugging runs over the
same wifi radio, so toggling it off drops adb along with the network —
expected, not a bug) meant this had to be confirmed via the server's
own log and MIKE-CU's copy rather than pulling MIKE-12R's file directly.

**Robustness finding, surfaced by an artifact of this test's setup, worth
knowing regardless:** the server's `hub.db` had been wiped clean
immediately before this test (routine between this session's many
tests) and MIKE-12R happened to reconnect before MIKE-CU did. MIKE-12R
correctly did *not* try to re-upload the lookup data it had inherited
via `resetNodeId()` (it didn't create that data, and correctly doesn't
claim to), but the new journal entry references lookup rows
(`status_id`/`who_id`/`domain_id`) that therefore didn't exist yet on
the fresh server — the merge failed with a real `FOREIGN KEY constraint
failed`, silently swallowed by `crdt_sync`'s internal try/catch (same
pattern as the earlier `sqlparser`/`android_metadata` findings). It
self-healed once MIKE-CU connected and supplied the missing lookup data
— but **only because MIKE-12R's connection happened to cycle again
afterward** (this device's already-documented background-connection
flakiness), triggering a fresh handshake that re-evaluated "what hasn't
the server acknowledged yet" and resent the same row, which then
succeeded. There is no dedicated retry-after-merge-failure logic in
`crdt_sync` — recovery here rode on an incidental reconnect, not a
guaranteed mechanism at the time. **Fixed the same session** — see
"Open items" below for the periodic-reconnect fix and its own
deterministic verification; that incidental recovery is now a
deliberate, scheduled one instead.

This was the last planned Part D item — see the top-level summary line
for this section for current overall status.

### WAL interaction — checked deliberately, a real correction to the old discipline

**The manual `PRAGMA wal_checkpoint(TRUNCATE)`-before-trusting-a-copy
discipline no longer applies to the sync mechanism itself — confirmed,
not assumed.** Under whole-file Syncthing sync, that discipline existed
because Syncthing copies the *file*; anything sitting uncommitted in the
`-wal` file was invisible to a synced copy until checkpointed first.
Record-level sync doesn't copy files — it reads live via `crdt.query()`,
and WAL mode's entire design point is that a query always sees the
latest committed data regardless of checkpoint state, main file or WAL.
Verified directly: wrote a row to the real `essentials.db` with **no
checkpoint before or after**, confirmed via file mtime/size that it
genuinely stayed WAL-only (main file's mtime unchanged, `-wal` grew),
and confirmed the real server received it live anyway. Also
re-confirmed `journal_mode` stays `wal` (not reverted to `delete`,
the project's own recurring past problem) across every real open this
session, including the freshly-rewritten `SqliteCrdt`-based
`DatabaseHelper`.

**The discipline still very much applies to anything that reads the file
directly instead of through SQL** — Letos, DBeaver, `adb pull`, a plain
file copy for backup. Learned this the concrete way earlier in this same
session, not in the abstract: a live-propagated test row was genuinely
on MIKE-12R, but invisible to a first verification pass that pulled only
the main `.db` file — it was sitting in the `-wal` companion, which
needs pulling (or a checkpoint first) too. So: trust the app to sync
correctly without a checkpoint; don't trust a plain file copy, `adb
pull`, or Letos to show current state without one. The server's own
`hub.db` is subject to the exact same rule.

**Given the checkpoint discipline is no longer load-bearing for the sync
mechanism itself**, the originally-planned "checkpoint on app
pause/close" feature (still listed under "Still to be built" further
up) is worth keeping anyway, but the reasoning for it has changed: not
sync correctness anymore, just keeping the `-wal` file from growing
unbounded and making ad-hoc Letos/DBeaver inspection and manual backups
less surprising day-to-day.

### Open items — everything Parts A-D surfaced that's not yet closed out

All of Part A/B/C/D's actual test/verification work is done. What's left
is operational follow-up, collected here in one place rather than
scattered:

- ~~**`field_metadata`'s edit workflow is unresolved**~~ — **resolved.**
  Built `FieldMetadataScreen` (reached from Settings) rather than the
  Letos workflow -- see "Letos/DBeaver workflow going forward" below for
  the write-up. `field_metadata` edits now go through the same
  `crdt.execute()` path every other table uses, so they actually sync.
- ~~**"Add column" screen**~~ — **built.** `SchemaEditorService`
  (`lib/db/schema_editor_service.dart`) generates and runs a validated
  `ALTER TABLE ... ADD COLUMN` against this device's own database;
  `AddColumnScreen` (reached from Settings, next to Field Labels &
  Defaults) is the pick-table/name/type/nullable/default UI, with a live
  DDL preview and a copy-to-clipboard success dialog (for pasting the
  exact statement into the server's `hub.db` by hand). Deliberately
  single-device, same as the rest of "Letos/DBeaver workflow going
  forward" below — running this screen on MIKE-CU doesn't touch MIKE-12R
  or the server; Mike still triggers it again on each. `NewColumnType`
  offers Text/Integer/Decimal/Yes-No, where Yes/No is a convenience
  preset (`INTEGER NOT NULL DEFAULT 0/1`) matching
  `TableDiscoveryService`'s own boolean-detection heuristic exactly, so a
  column added this way is auto-recognized as a checkbox field with no
  `field_metadata` override needed. A `NOT NULL` column always requires a
  default (SQLite's own restriction on `ADD COLUMN`), enforced in the UI
  before it reaches SQLite's less friendly rejection. Verified via
  `flutter analyze` (clean) and the full test suite (52/52 passing run
  serially — an initial parallel run showed 2 failures, but that traced
  to pre-existing cross-file test concurrency against the real
  `essentials.db`, not this change: `table_discovery_smoke_test.dart`
  passes cleanly alone, and a serial full run passes too). Discovery
  still only runs at launch (same as "Add table" above), so a newly added
  column needs an app restart before it shows up in the grid/form on the
  device it was added on.
- ~~**MIKE-12R needs the battery-optimization exemption set**~~ —
  **done, and confirmed fixed, not just applied.** Mike set it (Settings
  → Battery → essentials_app → allow background activity). Re-tested
  properly afterward: locked MIKE-12R's screen (confirmed via `dumpsys
  power` showing `Dozing`), waited well past the screen timeout with the
  device fully idle, then pushed a live change from MIKE-CU. It arrived
  and merged correctly (`is_deleted = 0`, pulled and confirmed off the
  device) while the phone was still asleep the entire time, with no
  disconnect logged anywhere in the exchange — the exact scenario that
  reliably killed the connection before this setting was applied. Root
  cause and fix both confirmed, not just theorized.
- ~~**No guaranteed retry after a server-side merge failure**~~ —
  **fixed.** `SyncService` now forces a disconnect+reconnect every 5
  minutes even on an already-healthy connection, since a fresh handshake
  is the only thing that re-triggers a resend of anything the server
  never actually acknowledged (`crdt_sync` has no ack/retry mechanism of
  its own). Verified with a deterministic reproduction, not just
  reasoning about it: two throwaway nodes, a fresh empty server, one
  node inheriting the other's data via `resetNodeId()` and writing a row
  that references data it doesn't own (same shape as the real failure).
  The write stayed stuck through periodic reconnects while the data
  owner was offline (correctly), then recovered automatically and
  unattended on the very next scheduled reconnect once the owner
  connected and supplied the missing data — zero manual intervention.
- ~~**Auto-start for the server**~~ — **done, then upgraded to a tray
  icon.** Not a Windows Service -- a Startup-folder shortcut
  (`shell:startup`), launching a real compiled executable (`dart build
  cli`, not `dart compile exe` -- `sqlite3`'s build hooks aren't
  supported by the older compile command). Decided against Task
  Scheduler: getting both "starts minimized" and "restarts if the
  process crashes" needs an intermediary wrapper (`cmd /c start /min
  ...`) that breaks Task Scheduler's own crash-detection, since it ends
  up tracking the wrapper's near-instant exit rather than the server's
  actual lifetime -- not worth that fragility for a problem ("forgot to
  start it after a reboot") the Startup folder already solves directly.
  Triggers on login (not before, not headless) -- Mike's explicit choice
  over the more "proper service" version.

  First version showed a minimized console window; Mike then asked for
  a system tray icon instead of a taskbar entry. Built with PowerShell's
  built-in WinForms support (`System.Windows.Forms.NotifyIcon`, no new
  software) rather than pulling Flutter/a GUI package into a console
  project. Three pieces, all in `essentials_app/server/`:
  `launch_tray_hidden.vbs` (the Startup shortcut's actual target --
  `WScript.Shell.Run(cmd, 0, False)` launches PowerShell with truly zero
  visible window, unlike `-WindowStyle Hidden` alone which can flash
  one) → `tray_host.ps1` (creates the `NotifyIcon` with a right-click
  menu -- View log, Restart server, Exit -- and starts `server.exe` as
  its own hidden child process, stdout/stderr redirected to
  `server.log`/`server.err.log`) → `server.exe`. Deliberately three
  separate processes, not one process being both console server and
  tray app: if the tray host ever crashes, the sync server -- a genuine
  child process, not dependent on the tray host staying alive -- keeps
  running unaffected.

  Verified for real, both versions: launched via the actual
  shortcut/launcher chain (not just the exe directly). For the
  minimized-window version, confirmed genuinely minimized (`IsIconic`
  via a Win32 check). For the tray version, confirmed via the process
  tree (`wscript` → `powershell` running `tray_host.ps1` → `server.exe`
  as its child) that no process has a `MainWindowHandle` (i.e. nothing
  in the taskbar), confirmed the port is actually listening and the log
  files are being written, and confirmed the old plain-`server.exe`
  instance was stopped and replaced by this one. See
  `essentials_app/server/README.md` for the rebuild/recreate commands.
- **MIKE-LP/MIKE-WP onboarding** — deliberately not started; the
  architecture is designed to make this easy once needed ("install app,
  point at the fixed server address"), but genuinely untested with a
  third/fourth device.

### Letos/DBeaver workflow going forward — decided, `field_metadata` resolved

**No record-level edits in Letos/DBeaver, full stop, going forward.**
Discussed at length: `sqlite_crdt` has no trigger-based fallback and no
touch/resync/reconcile mechanism at all (confirmed by grepping the
`sql_crdt`/`sqlite_crdt`/`crdt` package source directly — nothing) to
catch a write made outside its own Dart API. A record edited via Letos
never gets its `hlc`/`modified`/`node_id` touched, so it silently never
syncs to any other device — worse than whole-file Syncthing in this one
specific respect, since that was blind to *how* a file changed and
propagated any edit regardless.

**This also affects schema changes, not just data**, in a way worth
being explicit about: `sqlite_crdt` only ever syncs *row data* inside
existing tables — it has no mechanism for propagating a `CREATE TABLE`/
`ALTER TABLE`/`DROP TABLE` at all. The old whole-file Syncthing model
propagated a new table for free (it copied the entire binary file, schema
included); this one doesn't, ever. Every schema change now needs to be
applied identically, by hand, to all three real copies (MIKE-CU,
MIKE-12R, the server's `hub.db`) — routine work now, not just the
occasional-migration event it used to be.

**Add table** (rare — Mike's own framing: "nearly like creating a new app
in essentials_app"):
1. Pick the id scheme: reference/lookup table → `id INTEGER PRIMARY KEY
   AUTOINCREMENT`; real user-entered/offline-written table →
   `id INTEGER PRIMARY KEY DEFAULT (...)` (the timestamp+random
   generator — see schema.sql for the exact expression).
2. Write the `CREATE TABLE`: business columns, then `is_deleted INTEGER
   DEFAULT 0, hlc TEXT NOT NULL, node_id TEXT NOT NULL, modified TEXT NOT
   NULL` appended at the end. No default needed on `hlc`/`node_id`/
   `modified` — the table starts empty, so `NOT NULL` with zero rows to
   violate it is fine. Never name a business column `is_deleted`/`hlc`/
   `node_id`/`modified` (collides with the bookkeeping columns) — and see
   the `key`-column warning above for another reserved-word landmine.
3. Run that exact DDL on MIKE-CU, MIKE-12R, and the server's `hub.db`.
   MIKE-12R has no Letos — need a lightweight Android SQLite browser (or
   `adb shell` + `sqlite3`) for this and for "remove table"/"delete
   column" below.
4. Don't insert rows in Letos (see above) — let the app create the first
   row through its own discovery-driven form once it picks up the table.
5. Add it to `schema.sql`.
6. Restart the app(s) — discovery runs at launch, not live.

**Remove table / delete column** (rare, destructive — kept deliberately
manual and a little effortful, on purpose, same reasoning as not putting
a one-click "delete everything" button in an app used daily):
1. Confirm nothing worth keeping would be lost.
2. Pause sync everywhere (same discipline as a schema migration).
3. Apply identically to all three copies.
4. Verify (row counts / `integrity_check`) on each.
5. Resume sync.
6. Update `schema.sql`. Orphan cleanup handles leftover
   `field_metadata`/settings rows for a removed table automatically on
   next launch.

Deliberately **not** doing schema-change auto-propagation (e.g. storing
pending DDL as synced row data and having each device apply it
automatically on next launch) — sounds elegant, but it means a mistake
propagates silently to every device instead of being caught at the
"run it once, look at it, then do the next device" stage. The manual
per-device trigger is a feature, not friction worth engineering away.

**Add column: built into `essentials_app` itself** — additive, safe, and
probably the most common of these three operations as the schema
evolves. `TableDiscoveryService` already knows every table's live shape;
`crdt.execute()` already passes `ALTER TABLE` straight through unmodified
(only `CREATE TABLE` gets the bookkeeping-column rewrite — and that's the
exact code path with the `sqlparser` bug above, so `ALTER TABLE ADD
COLUMN` doesn't share that risk). `AddColumnScreen`/`SchemaEditorService`
(Settings → "Add a column") — pick table, name/type/nullable/default,
generate and run the `ALTER TABLE` — solves the MIKE-12R-has-no-Letos
problem cleanly for this one operation: same code generates the DDL on
both devices when Mike triggers it from the app's own UI on each, so
there's no hand-retyped SQL to get subtly wrong between them. Still
manual per-device (no propagation), and the server's `hub.db` isn't
running this app so still needs the generated DDL applied by hand — the
success dialog shows and copies the exact statement for that. `schema.sql`
still needs a manual update too, same as every other schema change.

**Bulk CSV import** — `schema.sql`'s own header names this as *the*
documented path for importing new data going forward, so it's the same
category of problem as ad-hoc Letos edits, just not yet resolved with a
concrete process. Sketch, not yet built or tested: stage the CSV into a
plain (non-tracked) table via Letos as usual, generate one `nodeId`+`hlc`
pair for "this import" (reuse the importing device's own real node id,
plus a fresh `Hlc.now(nodeId)` — same pattern the migrations above
already used), then one `INSERT ... SELECT` from staging into the real
table with `is_deleted`/`hlc`/`node_id`/`modified` (and `id`, if the
target uses the timestamp+random scheme — same rowid-alias/`DEFAULT`
gotcha as `GenericDao.insert()` above) supplied explicitly as literals.

**`field_metadata` — resolved: built the in-app screen, not a carve-out.**
Its old documented workflow ("edited via Letos, this app never writes to
it itself") was exactly the record-level-edit category ruled out above.
`FieldMetadataScreen` (reached from Settings → "Field Labels & Defaults")
now owns this instead: list every override, add/edit one (table + field
pickers populated live from real discovery/`PRAGMA table_info`, so you
can only ever target a column that actually exists), remove one. Writes
go through `FieldMetadataDao.upsert()`/`.deleteOne()`, both plain
`crdt.execute()` calls — same sync pathway as everything else now, no
special handling needed.

Deliberately its own small screen, not routed through the existing
generic list/form screens: those assume every table has a single-column
`id` primary key (`GenericDao.update()`/`.delete()` are hardcoded to
`WHERE id = ?`), but `field_metadata`'s real key is the composite
`(table_name, field_name)`. Reworking the generic CRUD machinery to
support composite keys generically, just for this one table, would have
been a much larger and riskier change than a purpose-built screen —
worth remembering as the reason if a similar composite-keyed table
(`table_column_settings`, `table_view_settings`, `device_settings`,
`table_group`) ever needs its own in-app editor too: same shape of
problem, same answer (a small dedicated screen, not a generic rework).

**Current interim state, unchanged from before this session —
`essentials_app` is fully disconnected from Syncthing on both MIKE-CU and
MIKE-12R.** Unshared, not just paused. MIKE-12R keeps its own local copy
of `essentials.db`, but purely for exercising the UI — not kept in sync
with MIKE-CU by any mechanism yet (Part D, not started). **Code is free
to overwrite MIKE-12R's copy as needed** (e.g. via `adb push`) until
Part D is complete — same force-stop-first, push-then-pull-back-and-diff
pattern already proven twice during the empty-db-propagation recoveries.
Obsidian's Syncthing folders are unaffected by any of this.

## Working style / constraints

- Mike is a semi-retired Global IT professional — technical, direct,
  fact-over-hedge. Corrects mistakes plainly; expects the same in return.
- **Mike does his own interactive UI/UX testing** (Windows clicking, Android
  via VS Code's F5) — this replaced Claude driving screenshot/ADB-based
  click-through verification after the batch-2 session, where watching that
  "hunt and peck the screen," especially with every action needing
  approval, was slower and more painful than Mike just doing it himself.
  Claude's job stops at build+verify (`flutter analyze`, `flutter build
  windows`/`apk`, direct SQLite queries against `essentials.db` to confirm
  data) and handing off; don't default back to self-driven UI automation
  unless explicitly asked.
- Dart/Flutter code cannot be compiled or run outside this local
  environment — that's the whole point of doing this work in the Code tab
  rather than browser chat: closes the loop that used to require manually
  copy-pasting errors back and forth. (See "Interactive terminal / hot
  reload constraint" above for the one real limit on this — Code verifies
  and builds, VS Code runs the live hot-reload loop.)
- Python here is 3.14.6, managed via `pymanager` (`py install --update`).

## Working across Claude Desktop's Chat and Code tabs

Chat (claude.ai-style conversation) and Code (this session) do **not** share
awareness of each other. Neither one sees what the other is doing unless it's
written down here. Ground rules:

- **Local mode requires a folder** — "Local" isn't a mode you pick separately
  from choosing a folder; selecting the folder *is* what Local mode does.
- **A session's full history is saved to disk.** Resuming an existing
  session (e.g. after a reboot) picks up exactly where it left off — same
  context, same in-progress work, nothing lost.
- **A *new* session starts cold.** It does not inherit history from other
  sessions, even other sessions in this same project. It loads this file
  (`CLAUDE.md`) plus Auto Memory automatically, but not prior
  session-specific conversation.
- **Claude Code has its own Auto Memory**, separate from this file — notes
  Claude writes to itself during a session (build commands, debugging
  insights, corrections given mid-session), stored locally on this machine
  and loaded automatically into future sessions in this folder. Check it
  anytime with `/memory`. Treat `CLAUDE.md` as the deliberate rules *you*
  write; Auto Memory as notes *Claude* takes on its own — useful, but not a
  substitute for writing down anything that must never be forgotten.
- **Chat's memory (claude.ai-style) and Code's memory are entirely separate
  systems that do not sync.** A decision made in Chat won't appear in Code
  automatically, and vice versa. This file is the only deliberate bridge
  between the two — update it whenever either side makes a decision or
  learns something durable, so the other side can pick it up.
- **New Code sessions default to whatever folder was last used**, not a
  fresh choice — click the folder name in the bar above the message box to
  explicitly change it (e.g. away from Essentials over to `essentials_app`)
  before starting a new session in a different project folder.

**When to resume vs. start a new session:** stay in the same session for one
continuous piece of work, even across a reboot. Start a new session at a
natural milestone boundary — update this file at that boundary so the new
session starts already knowing what the last one concluded.

**"CRUD Foundation + Domain" session, concluded.** Built the reusable
architecture (db layer, `TableConfig` model, generic list/form screens,
RESTRICT-aware delete, responsive nav), proved it against `domain`, then
reworked the list view twice more at Mike's request — first into a
hand-rolled multi-column grid, then swapped entirely to TrinaGrid once
the hand-rolled version couldn't cleanly do a frozen header +
resizable/frozen columns (see "List view is a real data grid" above).
Finished by adding the remaining nine batch-1 tables and replacing
`NavigationRail` with a hand-rolled scrollable rail once 10 destinations
overflowed it. **Batch 1 is now fully built and verified end-to-end on
both Windows and Android (CPH2611).** Commits: `ca05278`, `04a7aa8`,
`52fdb16`.

**"Batch 2" session, concluded.** Built all nine batch-2 `TableConfig`s
(`person`, `category`, `time_frame`, `account_type`, `account`, `supplier`,
`shipper`, `shipment`, `journal`) against the schema and real migrated
data already in `essentials.db` — no new Excel/migration work needed, that
part was already done. `FieldConfig.lookup`/`LookupConfig` (shaped since
the CRUD-foundation session, never exercised until now) turned out to work
immediately in the form screen, but exposed a real gap in the grid, fixed
in two passes — see "Real friction surfaced" above for both: (1) id →
display-text resolution in `GenericListScreen` plus a related bug in how
the actions column rebuilt rows for the edit form, then (2) Mike flagged
that read-only wasn't good enough — "should work the same as they do in
form view" — so lookup columns were reworked into genuinely
inline-editable dropdowns via `TrinaColumnType.select`, which in turn
surfaced the `shadcn_ui`/`ShadTheme` dependency gap (that popup-menu column
type silently fails to open without a `ShadTheme` ancestor — see `main.dart`).
Verified end-to-end on Windows (largest table so far, `journal`'s 298
rows; first table with two simultaneous lookups, `account` → `account_type`
+ `domain`; a required lookup with no blank/clear option, `time_frame` →
`unit`), then **on Android (CPH2611) via a fresh APK install** — same
three cases, plus a null/clear selection correctly persisting. One real
scare along the way: a test edit appeared to leave Mike's `person` row
with a null `gender_id` on the *Windows* copy of `essentials.db`, even
though the edit happened on the Android grid — turned out to be Syncthing
actually working as documented, propagating the change (and, moments
later, its Windows-side fix) between devices within the session. Worth
remembering this can happen: a change on one device can show up on the
other's copy within seconds, not the "eventually, sometime later" mental
model that's easy to default to. The stray `newdomain` test row Mike
spotted along the way has been deleted.

**"Batch 3" session, concluded.** Built `subscriptionConfig` (7 FK
fields) against the same lookup-field pattern batch 2 already proved, plus
two new `TableConfig`/`FieldConfig` primitives for `yearly_cost`/
`next_date`: `readSource` (query `subscription_computed` instead of the
bare table for reads; writes still target `subscription`) and `readOnly`
(no editor, never written). `payment_method_id`'s `LookupConfig` displays
`account.code`, not the default `name` — see "Known data quirks" below.

**Two staleness bugs surfaced immediately** once Mike started editing real
rows: editing `Cost` didn't refresh `Yearly Cost` in the grid until
switching tables and back, and the form didn't refresh it at all before
Save. Fixed differently in each place, deliberately: the **grid** just
re-fetches the whole row from `readSource` after any inline edit on a
table with `readOnly` fields (cheap, and correct by construction — no
need to hardcode which columns feed which computed one). The **form** has
no view row to re-query until the row is saved, so `TableConfig
.computePreview` was added: an optional Dart-side mirror of the view's
SQL formula, called when the user leaves (not on every keystroke) a field
that might feed a computed one. This is a deliberate, narrow exception to
"never duplicate the formula" — scoped to a preview only, never written on
save, so any drift between the Dart copy and schema.sql's real formula is
cosmetic and self-corrects the moment the row is saved and reloaded.

**Cross-cutting feature added in the same session, across every table, not
just `subscription`:** any `FieldConfig.isLink` column (`supplier`/
`shipper.hyperlink`, `shipment.order_link`/`tracking_link`,
`journal.link`, `subscription.link`) now renders as blue/underlined text
with an "open in new" icon, in both the grid and the form, opening in the
system default browser via the new `url_launcher` dependency. Deliberately
kept editable, not read-only — in the grid this meant the *only* new tap
target is the small icon, so a plain tap/double-tap anywhere else in the
cell still reaches TrinaGrid's own select/edit handling instead of racing
with link-opening. Needed Android `<queries>` entries for http/https
package visibility (Android 11+) — hit one real bug adding those: a bare
`--` inside an XML comment breaks Gradle's manifest merge (XML comments
can't contain `--` anywhere in their body, not just at the very end).

**One more bug, caught by Mike doing his own Android testing via VS
Code's F5** (see "Working style" below for why this is now the default
mode rather than Claude driving screenshots): opening the edit form for a
`shipment` row briefly flashed Flutter's red debug-mode error overlay,
too fast to read, then recovered. Root cause: `DropdownButtonFormField`
asserts its value matches exactly one item unless `items` is empty or the
value is `null` — during the one frame before a lookup field's
`FutureBuilder` resolves, its stored FK id isn't in the (still-loading)
`items` list yet. Required fields dodge this by accident (their `items`
list starts genuinely empty, which the assertion explicitly exempts);
optional ones always have a blank placeholder item, so they don't. Only
ever visible in debug builds (`flutter run`/F5) — Dart strips `assert()`
from release builds, which is why this never showed up in the release APK
testing during the batch-2 session. Fixed by falling back to a `null`
initial value until the stored id is actually present among the loaded
options; `DropdownButtonFormField`'s own `didUpdateWidget` picks up the
real value once it arrives, so there's no stuck-blank side effect.

**Next session:** no more table-config batches queued. Mike is using the
app for real now — see "Real-usage findings" above for the three
functional requirements that surfaced almost immediately (grid state
persistence, sidebar grouping, a settings framework) and the working
agreement for this phase (Chat shapes requirements from what Mike notices
in real use; Code implements once something's actually scoped, not before).
`Order`/`OrderItem` parent-child work stays on hold until that migration
happens and/or this phase settles down.

**"Settings & Persistence Architecture" session, concluded.** Steps 1-2
of the build order under "Real-usage findings" above built together (they
share one checkpoint — Restore Defaults is a thin wrapper around Step 1's
dao) and build-verified (`flutter analyze`, `flutter build windows`,
`flutter build apk --debug` all clean); **not yet Mike-verified
interactively** — per the working agreement, that's next before Step 3
starts.

- `table_column_settings`/`table_view_settings` added to `schema.sql` and
  applied directly to the live `essentials.db` (plain DDL via `sqlite3` —
  no data migration involved, so the CSV/Letos path wasn't needed for this).
- `lib/util/device_id.dart` + a `MainActivity.kt` platform channel resolve
  the live per-device id — see "Real-usage findings" above for the
  Windows/Android implementation split this surfaced.
- `lib/db/table_view_settings_dao.dart` is the new dao: load/save column
  settings (whole-set replace, not per-column upsert) and view settings
  (sort/filter), plus `restoreDefaults()` for the Restore Defaults button.
- `GenericListScreen` changes, all in `lib/screens/generic_list_screen.dart`:
  - `id` and the actions column stay structurally fixed (never customized,
    never persisted) — only `TableConfig.fields` columns are, matching the
    "TableConfig's declared defaults" framing in Step 2's spec.
  - **No new UI needed for resize/reorder/sort/filter/hide/freeze** — all
    of that already came free from TrinaGrid (drag-reorder, drag-resize,
    click-to-sort, and the per-column header's built-in context menu for
    filter/hide/freeze/autofit). This screen only captures that state and
    replays it on the next load. The one new UI element is a small
    "Restore default view" icon button in the AppBar.
  - Capturing state turned out to need two different listeners, not one:
    `TrinaGridStateManager` itself (a plain `ChangeNotifier`) fires for
    reorder/sort/filter/hide/freeze, but **column resize goes through a
    separate `resizingChangeNotifier`** that the main listener never sees
    — traced by reading the library source (`layout_state.dart`), not
    documented anywhere. Both are wired into the same debounced save.
  - The debounce (600ms) also absorbs plain cell edits and selection
    changes, which fire the same listener but aren't grid-state changes
    worth persisting — a snapshot-equality check before each write (skip if
    identical to what's already saved) keeps those from generating no-op
    writes, cheaper than trying to filter the listener by mutation type
    (TrinaGrid's own notifier-hash filtering turned out unreliable for
    this — plain `notifyListeners()` calls elsewhere in the library, e.g.
    cell edits, pass no hash and match any filter by the library's own
    design, so hash-based filtering couldn't actually exclude them).
  - Every reload (including the existing computed-field-triggered reload
    from the batch-3 session) already fully remounts `TrinaGrid` — the
    `FutureBuilder`'s brief loading-spinner frame swaps the widget type at
    that tree position, so Flutter tears down and rebuilds
    `TrinaGridStateManager` from scratch rather than updating it in place.
    This turned out to be exactly the right hook: `onLoaded` fires fresh on
    every reload, not just the first, so reapplying saved sort/filter there
    works uniformly regardless of why the reload happened.
- **Found, not yet fixed by this work:** WAL mode had silently reverted to
  `delete` at some point before this session — see "Sync architecture"
  above. Unrelated to this session's changes as far as could be determined,
  but caught while touching the db, so re-enabled and flagged here rather
  than left for the next session to rediscover.

**Windows (MIKE-CU) interactive verification: done, passed.** Mike confirmed
the settings tables work as intended on MIKE-CU.

**Android (MIKE-12R) + cross-device isolation: done, passed.** Mike opened
the app on MIKE-12R, resized/froze some columns on `domain`/`priority`,
closed it, waited for Syncthing to finish, then inspected both
`table_column_settings` and `table_view_settings` in Letos on MIKE-CU.
Confirmed: MIKE-CU's own rows (`domain`/`priority`/`gender`) were completely
unaffected by MIKE-12R's writes after the sync round-trip — real proof
`device_id` scoping holds across an actual Syncthing sync, not just locally.
Also confirmed by inspection: `id`/the actions column never leak into
`table_column_settings` (every row is a real `TableConfig.fields` column),
and the non-round widths seen for sibling columns are `TrinaResizeMode
.normal` redistributing width when an adjacent column is dragged — expected
behavior, faithfully captured, not a bug.

**Restore Defaults: done, passed on MIKE-12R.** Reverted correctly.

**Unrelated bug found during that same pass, fixed same session: the
`Active` checkbox silently stopped registering taps in the grid on
MIKE-12R** (cell would select, checkbox never toggled; form view's switch
worked fine). Root cause, in pre-existing code this session never touched:
the boolean column is `readOnly: true` by design (keeps TrinaGrid's own
text/number editor from opening — the `Checkbox` renderer is meant to be
the only way to edit it), but `changeCellValue()`'s default readOnly gate
can't distinguish "readOnly so TrinaGrid's editor shouldn't open" from
"readOnly so this cell can never change" and was silently rejecting every
toggle before it ever reached the db-write callback. Fixed by passing
`force: true` from the checkbox's `onChanged`. **Open question, not
resolved:** batch 1's write-up claims this was "verified end-to-end...
inline cell edits... on both Windows and Android" — given the code
structurally could never have worked without `force: true`, either that
verification pass didn't specifically exercise the checkbox (most likely),
or something changed since. Not worth chasing further; noting so a future
"but this used to work" moment isn't a mystery. **Not yet retested
on-device** — Mike is re-verifying the checkbox toggle on MIKE-12R before
Step 3 starts.

Step 1-2 are otherwise fully closed — both platforms verified, Restore
Defaults verified, checkbox fix confirmed working on MIKE-12R.

**Step 3: done.** `app_settings`, `device_settings`, `field_metadata`,
`table_group` all added to `schema.sql` and applied to the live
`essentials.db` (plain DDL, no data migration). No Dart/UI work this
step, per plan — schema only, verified via direct query. Also found and
fixed, unrelated to this step's own work but hit while F5-testing the
checkbox fix: **VS Code's F5 install to MIKE-12R over USB fails
intermittently** (`adb.exe: failed to install...`/`ADB exited with exit
code 1`) — confirmed, via the device's adb `transport_id` changing between
two calls seconds apart, to be a USB-level connection drop, not a
build/app problem; see "Toolchain setup" above for the workaround (manual
`adb install -r`) and the wireless-adb direction flagged for later.

**Step 4: built, build-verified (`flutter analyze`, `flutter build
windows`/`apk --debug` all clean); not yet Mike-verified interactively.**

- `lib/db/sidebar_grouping_dao.dart`: `loadMembership`/`moveTableToGroup`/
  `removeFromGroup` against `table_group` (shared); `loadCollapsedGroups`/
  `setGroupCollapsed` against `device_settings` (per-device, keyed
  `sidebar_collapsed:<group_name>`) — two different sync scopes for two
  concerns that look like one thing ("sidebar state") from the UI side,
  same governing rule as everything else in this phase.
- `home_shell.dart` rewritten: both the Windows rail and Android `Drawer`
  now render collapsible group sections built from the same
  `_buildGroups()` helper, sharing the drag logic (only the item widget's
  visual style — compact icon column vs. `ListTile` — differs between
  layouts, same as before grouping existed).
- **Interaction: long-press-drag a table onto a group header to move it,
  or onto a "New group" drop target to create one.** No separate
  create-empty-group action exists — `table_group`'s schema (one row per
  *table*, no standalone groups table) has no way to represent a group
  with zero members, so a group only comes into existence the moment a
  table is dropped into it (typed name via a small dialog on drop).
  `LongPressDraggable`, not a plain `Draggable` — a quick tap still reaches
  the item's own `onTap` for normal navigation; only a held press starts a
  drag, so drag and tap-to-navigate don't compete for the same gesture.
- **Tables with no `table_group` row render under a synthetic "Ungrouped"
  bucket** — not a real persisted group. Dragging a table back onto that
  bucket's header calls `removeFromGroup` (deletes the row) rather than
  writing a group literally named "Ungrouped." Every table starts here
  before it's ever been organized, so the nav list is never empty.
- **Group display order isn't a stored column** — `table_group` only
  carries `group_position` (a table's position *within* its group).
  Derived instead from first-appearance order among `registeredTables`:
  whichever group a table lands in earliest (by the existing batch-1/2/3
  nav order) determines that group's position in the list. Deterministic,
  needs no schema addition, and means "Ungrouped" naturally sorts first
  until something's actually been dragged out of it.
- Selection tracking changed from an index into a flat list (`_selectedIndex`
  into `registeredTables`) to `_selectedTableName`, looked up by name —
  necessary once the visual order (grouped) and the underlying config list
  order (flat, `registeredTables`) can diverge.

**Found immediately by Mike's own testing, fixed same session: drag-and-drop
was effectively unusable as the only way to move a table between groups.**
Two compounding problems: (1) the standalone "New group" drop target had
no `onTap` at all, so clicking it (the natural first thing to try) did
nothing, with no indication it was drag-only; (2) `LongPressDraggable`
requires pressing and holding *still* before a drag starts — any early
movement cancels it — which is easy to lose to the rail/drawer's own
scroll gesture and isn't discoverable without already knowing the exact
gesture. Rather than debug the gesture-arena conflict blind (not
testable interactively from Code), added a reliable path alongside the
existing drag machinery instead of replacing it: a small "..." menu on
every table item (rail and drawer) listing every existing group plus "New
group..." — works identically via click or tap, no gesture-timing
dependency. Removed the standalone drop-only "New group" target since
group creation now always goes through the per-item menu, which has
table context already.

**Follow-up from Mike after trying it: drag-and-drop itself was fine (that
was always the intended click-and-hold-and-drag gesture) — the "..." icon
button was just an unnecessarily fiddly way to reach the menu.** Swapped
it for right-click (`onSecondaryTap`) directly on the table item, same
menu. Drag-and-drop stays as-is alongside it. Android has no secondary-tap
gesture on touch, so long-press-drag remains the only path there — not a
gap Mike flagged, not addressed further.

**MIKE-12R interactive pass: done, passed.** Moved a table from Ungrouped
to a real group via long-press-drag (confirmed working reliably on Android
touch — the earlier drag reliability concern was specific to the Windows
rail competing with its own scroll gesture, not a general problem),
collapsed both groups, closed and reopened the app — everything persisted
exactly as left. Core Step 4 functionality confirmed on both platforms.

**Two more bugs found by that same pass, fixed same session:**
- **No way to reach the move-to-group menu on Android at all.** Right-click
  has no touch equivalent, and long-press was already claimed by drag, so
  once the menu moved behind `onSecondaryTap` (see the "..." → right-click
  swap above), touch-only devices lost their only path to it. Fixed with a
  full-size trailing icon on the drawer's table items — deliberately not
  the same cramped rail-style icon Mike already flagged as fiddly; the
  drawer has the room for a proper `ListTile.trailing` tap target.
- **Flutter's own framework assertion fired live on-device:** "ListTile
  background color or ink splashes may be invisible" — the drawer's group
  header wrapped `ListTile` in a plain colored `Container` for the
  drag-hover highlight, which sits between the `ListTile` and the nearest
  `Material` ancestor it paints its splash on, hiding it. Fixed by using
  `Material(color: ...)` instead, which paints at the correct depth.
  Cosmetic, not a crash, but worth remembering as a general pattern: never
  wrap `ListTile`/other Material-splash widgets in a plain colored
  `Container` for a highlight effect — use `Material`'s own `color`.

**Step 4 is done.** No open items remain.

**Step 5: built, build-verified (`flutter analyze`, `flutter build
windows`/`apk --debug` all clean); not yet Mike-verified interactively.**

- `lib/theme/theme_preset.dart`: two presets, `Light`/`Dark` — deliberately
  minimal (Mike hasn't asked for more), each just a `Brightness` + seed
  `Color` for `ColorScheme.fromSeed`. Preset font/background/text colors
  are *derived* from the generated `ColorScheme` (`.surface`/`.onSurface`)
  rather than hardcoded hex — stays in Material 3's color harmony
  automatically, only diverges when Mike sets an explicit override.
  Font family choices are a curated list (`Roboto`/`Georgia`/`Consolas`/
  default), not free text — no font assets are bundled in this project, so
  an arbitrary name would just silently fall back to the platform default
  anyway; curating avoids a picker full of options that all look the same.
- `lib/theme/theme_controller.dart`: `ThemeController` (singleton
  `ChangeNotifier`, same pattern as `DatabaseHelper.instance`) owns the
  base-plus-override merge — `themeData` getter resolves each of the four
  overridable attributes (font family/size/color, background color)
  independently against the active preset, matching CLAUDE.md's override
  model exactly. `main.dart` wraps `MaterialApp` in a `ListenableBuilder`
  so the whole app re-themes live the instant any setting changes.
- **Load-timing decision, worth remembering:** `ThemeController.load()` is
  *not* called from `main.dart` at app root — Android's db isn't reachable
  until `PermissionGate` confirms `MANAGE_EXTERNAL_STORAGE`, so loading
  earlier would race that screen's own permission flow (same category of
  issue as the empty-db incident above, avoided by design this time
  instead of found the hard way). Called from `HomeShell.initState`
  instead, fire-and-forget — the first point the db is known reachable on
  both platforms. Until it resolves, the app shows the default preset with
  no overrides, not a blocking spinner at the very top of the tree.
- `lib/screens/settings_screen.dart`: one screen, dropdown (theme) +
  dropdown (font family) + slider (font size, labeled "this device") + two
  hex text fields (font/background color) with a "Reset to theme" button
  next to each *only when an override is currently set* — clearing a
  field's override needs its own affordance beyond "type nothing," since
  blank vs. "0 as a real value" isn't ambiguous for colors/fonts but the
  UI still needs an explicit way back to "no override" once one exists.
  Dropdowns/slider write through immediately; the two hex fields write on
  submit/focus-loss, not per keystroke (same "don't write on every
  interaction" instinct as Step 1's debounce, just via a different
  mechanism since these are discrete edits, not a drag).
- New "Settings" entry added to both the rail and drawer, opening the
  screen via a normal `Navigator.push` — not folded into the per-table nav
  list, since Settings isn't a table.
- Schema: no changes needed — `app_settings`/`device_settings` already
  existed from Step 3.

**Windows interactive pass: done, core claim confirmed.** Mike set an
explicit font/color override, switched themes, and confirmed the override
survived instead of being overwritten by the new theme's default — the
actual thing the override model claims. Font-size-is-per-device and
Android verification are still open, not yet run.

**Bug found by that same pass, fixed same session: TrinaGrid ignored the
app theme entirely.** Switching to Dark re-themed the window chrome and
the form, but not the grid — TrinaGrid has its own independent styling
system (`TrinaGridStyleConfig`) that never reads Flutter's ambient
`Theme`, so it stayed hardcoded light regardless of what
`ThemeController` set everywhere else. Fixed in `GenericListScreen`: a new
`_trinaGridStyle(context)` starts from TrinaGrid's own built-in light/dark
preset (closest match for borders/hover/selection colors this app has no
opinion on) and overrides just background/text color to match the
resolved theme.

**Also done this pass, not originally scheduled until Step 6 but Mike
asked for it now:** a popup color picker (new `flutter_colorpicker`
dependency) wired into the Settings screen's font/background color
fields — a swatch button next to each hex field opens it; values stay
stored as hex strings, unchanged from manual entry. **Scope note: this is
the Settings-screen half only.** Step 6's original target (`domain.color`/
`class.color`/etc. — the hex fields already visible in the grid/form
today) is still open; same picker widget (`lib/util/color_picker.dart`),
just not wired into `FieldConfig`'s color-type fields yet.

**Step 6: done, same session.** `FieldConfig.isColor` now marks every real
`color` column (all eight lookup-table configs) — same relationship to
plain text `isLink` already has, not a new field type. Grid: clickable
swatch renders before the hex text in the cell, double-click elsewhere
still opens TrinaGrid's normal text editor (same "swatch is the only new
tap target" pattern as the link icon). Form: swatch prefix icon that
live-updates as you type a hex value directly, plus a palette suffix icon
opening the same picker dialog the Settings screen uses. Values stay hex
strings everywhere, unchanged from manual entry — build-verified, not yet
Mike-tested.

**Android verification: done, passed.** Theme/font/color settings work
independently per the shared-vs-per-device model, confirmed on-device.
Color picker (Step 6) confirmed working in both the grid (swatch beside
the hex, "nice touch" per Mike) and the form, on both platforms.

**Steps 1-6 are all done and verified on both platforms. The Settings &
Persistence Architecture phase's planned build order is complete.**

**Follow-up, same phase: within-group table ordering** — Mike asked for
this once Step 4 was otherwise done ("sort the tables within a group or
even drag order them"). Built both:
- `SidebarGroupingDao.setGroupOrder(groupName, orderedTableNames)` —
  whole-set replace of a group's `group_position` values, same reasoning
  as `TableViewSettingsDao.saveColumnSettings`.
- **Drag-to-reorder:** every table item is now also a `DragTarget`, not
  just group headers — dropping table A onto table B reorders A to sit
  immediately before B within B's group. Doubles as precise cross-group
  placement (not just append-at-end) if A wasn't already in that group.
- **Sort A-Z:** one-click alphabetical sort per group, a small icon next
  to each group header, for when dragging isn't worth it.
- Neither applies to the synthetic "Ungrouped" bucket — no `table_group`
  row exists to position anything against there.
- Verified on both MIKE-CU and MIKE-12R — drag-to-reorder and Sort A-Z
  both confirmed working.

**Retrospective:** the longest, highest-stakes session of the project so
far — not because any one step was individually hard, but because this
was the first phase where both platforms could write real data
simultaneously and something actually went wrong because of it (the
empty-db-over-Syncthing incident, "Incident" writeup above). Worth
remembering going forward: real data was never actually lost, but only
because Syncthing's own versioning happened to have a backup and Code
checked before writing anything — not because the app protected itself.
`database_helper.dart`'s loud-failure-instead-of-silent-empty-db fix
closes that specific hole; the broader single-writer discipline
(CLAUDE.md "Sync architecture") is still a manual habit, not enforced in
code. Also the session with the most Mike-caught bugs of any so far
(checkbox `force: true`, TrinaGrid ignoring the theme, the ListTile/
Material ink-splash assertion, the missing Android menu path) — every one
found by Mike actually using the feature, not by Code's own build+verify
pass, which is exactly the working agreement doing what it's for.

Six planned steps plus two follow-ups (within-group ordering, the
color-picker scope extension to grid/form fields) all shipped, built, and
verified on both platforms. Mike's framing at the close: "now we have an
application" — batches 1-3 proved the CRUD pattern against real,
already-migrated data; this phase is what turned it from "a set of
generated screens" into something with actual per-user configuration,
persistence, and polish. **Next session:** not yet decided — either
resume `Order`/`OrderItem`, or keep following real-usage friction with
Chat, per the working agreement (Chat shapes scope from what Mike
notices; Code implements once it's actually scoped).

**Date/dateTime picker fields + grid row-height/wrap-text settings,
concluded (undocumented here until now — found already built,
build-verified, and uncommitted in the working tree at the start of the
Table Discovery session below; committed as its own checkpoint,
`b05d2c0`, before that session's work started).** `FieldType` gained
`date`/`dateTime`: grid columns render via `TrinaColumnType.date`/
`dateTime` (calendar popup on double-click, matching the lookup dropdown's
own interaction model), the form adds a calendar/event icon opening the
native date/time picker, and both normalize to schema.sql's plain ISO8601
`TEXT` convention via the new `lib/util/date_format.dart`. Applied to
`shipment`'s three date columns, `journal.entry_time`, and
`subscription`'s `start_date`/`next_date`/`last_date`. Separately, grid
rows gained a per-column "Wrap text" toggle (column header menu, backed by
a new `table_column_settings.wrap_text` bit, already added to
`schema.sql`/the live db) plus two new per-device row-height settings
(no-wrap and wrapped) in the Settings screen, read through
`ThemeController`/`ThemeSettingsDao`'s now-generic `device_settings`
key/value accessor (`loadDeviceSetting`/`setDeviceSetting`, with
`loadDeviceFontSize`/`setDeviceFontSize` now thin wrappers over it).
**Mike's interactive verification: done, passed, on both MIKE-CU and
MIKE-12R** — confirmed alongside the rest of the Table Discovery phase's
Android pass.

## New-table conventions (Part C -- documentation, not enforcement)

For a table created directly in Letos/DBeaver to come in through discovery
looking sensible (not technically-broken, just possibly odd-looking), it
needs a surrogate `id` column (never used as a `FieldConfig`, always the
structural id column) and snake_case naming throughout (table name and
every column). Two heuristics specifically depend on naming, not enforced
by the app: a column literally named `name` becomes the table's display
column; an `INTEGER NOT NULL DEFAULT 0`/`DEFAULT 1` column is read as
boolean (SQLite has no distinct boolean type, so this is the only signal
available -- see `lib/db/table_discovery_service.dart`). **A third,
schema-level (not naming-based) signal, added "Split-Pane Layout"
session:** absent a `name` column, a single-column `UNIQUE` text
constraint (e.g. `orders.order_number`) wins the displayColumn heuristic
over a plain `NOT NULL` text column -- worth declaring a real identifying
column `UNIQUE` in Letos when creating a table by hand, rather than
relying on the `NOT NULL` fallback or falling through to the bare `id`. A
table that violates these conventions won't error, it'll just introspect
into something that looks wrong (e.g. no sensible display column) -- worth
knowing before creating a table by hand, not something this app validates
or blocks.

**`id` convention changed, "Split-Pane Layout" session.** Every table
through `subscription` (all 19 original) declares `id INTEGER PRIMARY KEY
AUTOINCREMENT`. **`orders`/`order_items` — created directly in Letos —
use a different scheme instead, now the standing convention for every
table created from here on:**
```sql
id INTEGER UNIQUE NOT NULL DEFAULT (
    CAST(unixepoch('now','subsec') * 1000 AS INTEGER) * 1000
    + (abs(random()) % 1000)
),
```
Deliberately **not** declared SQL `PRIMARY KEY` — a millisecond-timestamp
+ random-suffix default instead of a simple incrementing counter, to avoid
id collisions between Windows and Android inserting new rows offline,
ahead of a Syncthing sync (`AUTOINCREMENT`'s per-connection counter can't
guarantee uniqueness across two independently-writing devices the way a
real UUID/snowflake-style value can). This is a genuine, deliberate
convention change, not a mistake to fix at the schema level.

**Consequence for discovery, already fixed:** `TableDiscoveryService`
identified the structural `id` column purely via `PRAGMA table_info`'s
`pk` flag, which is `0` for this scheme (it's `UNIQUE NOT NULL`, not `PK`)
— without a fix, `id` would show up as a normal editable integer
`FieldConfig`. Fixed by also matching a column literally named `id` by
name, regardless of the `pk` flag (`lib/db/table_discovery_service.dart`,
`_columnInfo`) — covers both id schemes going forward with one check, no
table-by-table special-casing needed.

**Extended to `journal`/`shipment`/`subscription`, "ID Primary Key
Conversion" session — done, verified.** Unlike `orders`/`order_items`
(fresh `CREATE TABLE`, trivial), these three already held real, populated
data (`journal` alone: 299 rows) and SQLite has no `ALTER COLUMN` — the only
correct mechanism is SQLite's own documented table-rebuild procedure
(`CREATE TABLE <t>_new` with the new `id` declaration and every other
column/FK/index unchanged, `INSERT INTO <t>_new SELECT * FROM <t>`,
`DROP TABLE <t>`, `ALTER TABLE <t>_new RENAME TO <t>`, all inside one
`BEGIN`/`COMMIT` with `PRAGMA foreign_keys` off/on around it). Existing rows
kept their original small sequential ids unchanged — only the `DEFAULT`
changed, affecting rows inserted from here on.

Three reviewable scripts, one per table, in `essentials_app/migrations/`
(`001_journal_id_convention.sql`, `002_shipment_id_convention.sql`,
`003_subscription_id_convention.sql`), each run as a single atomic script
via the `sqlite3` CLI (not statement-by-statement, and not through a GUI
tool — avoids the DBeaver gotcha where an early step renaming the table
away breaks a later step that still references the old name). Committed
one table at a time (`journal` and `shipment` first — simpler, prove the
procedure cleanly — `subscription` last, for its view wrinkle below), same
"simple case first, hardest case last" sequencing as batches 1-3 and Table
Discovery.

Verified per table, not just assumed: row count identical before/after,
`PRAGMA integrity_check` and `PRAGMA foreign_key_check` both clean, and a
full byte-for-byte dump-and-diff of every row (not just a spot-check)
showed zero differences for all three. `subscription_computed` (a view
resolving `subscription` by name at query time, not at `CREATE VIEW` time)
needed no changes of its own — confirmed directly by re-querying it
post-rebuild and diffing against a pre-rebuild dump: `yearly_cost`/
`next_date` matched exactly for all 14 rows. Table Discovery needed no new
work either (already generic from the `orders`/`order_items` fix above) —
confirmed via the existing `flutter test` regression suite, which queries
these three tables' discovered configs against the real live db and all
passed unchanged post-rebuild. `RESTRICT` spot-checked directly against the
live db post-rebuild too: attempting to delete a `domain`/`status` row
still referenced by `journal` and a `class` row still referenced by
`subscription` both still fail with a foreign key constraint error (each
attempt wrapped in a transaction and rolled back, so nothing was actually
mutated by the check itself). A real insert with `id` genuinely omitted
against each of the three live tables (also wrapped and rolled back)
confirmed the `DEFAULT` produces a real ~16-digit id, not a small
sequential one.

**Dart-side consequence, real code change, not just schema:** once `id` is
no longer a rowid alias, `sqflite`'s `Database.insert()` return value (the
internal rowid) no longer equals the new row's `id`. Nothing in the app
actually depended on that return value before this session (every add flow
reloads its list from the db afterward rather than trusting the insert
call's return — including `orders`/`order_items` already; this had been
sitting latent since the "Split-Pane Layout" session, just never
triggered), but it's exactly the kind of thing worth fixing now rather than
leaving for whichever future caller assumes the return value is real.
Fixed generically, not per-table: `GenericDao.insert()`
(`lib/db/generic_dao.dart`) now re-reads `id` by rowid inside the same
transaction immediately after inserting — correct under either id scheme,
since the two happen to be identical for an `AUTOINCREMENT` table anyway.
Covered by a new test (`test/generic_dao_insert_id_test.dart`) exercising
both schemes directly against throwaway tables.

## Table Discovery phase (in progress)

**Part D (table deletion handling) status, this session:**

- **`PRAGMA foreign_keys` on Windows: confirmed genuinely `1`** for this
  app's own connection (`test/table_deletion_handling_test.dart`, first
  case). **DBeaver's own setting is still the one open item from an
  earlier session, not closed out here** -- Code has no way to launch
  DBeaver itself; Mike needs to check DBeaver's own PRAGMA/connection
  settings directly and confirm `foreign_keys=1` is actually in effect
  there, the same way Letos was confirmed persistent-on previously.
- **RESTRICT-blocks-DROP-TABLE: verified directly, not just trusted from
  SQLite's docs** -- but against a **throwaway parent/child table pair**,
  deliberately, not the real `class`/`subscription` tables. Same
  underlying SQLite mechanism either way (`ON DELETE RESTRICT` doesn't
  care which table it's declared on), and this avoids the one real risk of
  testing it for real: if FK enforcement somehow *didn't* apply, an actual
  `DROP TABLE class` against the live, Syncthing-synced `essentials.db`
  would be a genuinely bad, hard-to-reverse outcome, not just a failed
  assertion. Confirmed: the drop fails with a foreign key constraint
  error, and the parent table is still there afterward, untouched.
- **CASCADE gap:** already documented (see "Parent-child (one-to-many)
  relationships" below) -- confirmed still accurate, nothing new needed
  here.
- **Orphan cleanup:** built (`lib/db/orphan_cleanup_service.dart`), runs
  once at startup alongside discovery (`lib/config/table_registry.dart`'s
  `loadEffectiveTables`). Covers `table_column_settings`/
  `table_view_settings`/`table_group`/`field_metadata`. **`device_settings`
  deliberately excluded** -- every key written there today
  (`font_size`, `sidebar_collapsed:<group_name>`) is keyed by device or
  group name, never `table_name`, so there's nothing table-scoped in it to
  orphan; revisit if a future per-table `device_settings` key convention
  ever gets introduced. Verified end-to-end in
  `test/table_deletion_handling_test.dart`: seeds one row in each of the
  four tables for a table that's then dropped, plus a control row for a
  table that stays alive (`domain`) -- cleanup removes exactly the
  orphaned rows and leaves the control row untouched.
- **Defensive nav check for a dropped hand-coded table: satisfied
  structurally, not via a separate explicit check.** `HomeShell` now
  drives its table list from `TableDiscoveryService.discoverTableNames()`
  (existence-filtered, always current) rather than iterating
  `registeredTables` directly -- a hand-written config whose table has
  been dropped is simply never looked up, so there's no code path left
  that could crash trying to render it. See `lib/config/table_registry.dart`.
- **Mid-session drop-elsewhere edge case: already handled, confirmed by
  code inspection, not interactively tested.** `GenericListScreen`'s body
  `FutureBuilder` already checks `snapshot.hasError` before checking for
  data (this was the exact bug fixed for `HomeShell` during the empty-db
  incident -- see "Incident" below -- and `GenericListScreen` was written
  correctly from the start). A table vanishing out from under an
  already-open screen means `GenericDao.getAll()` throws (`no such table`),
  which surfaces as `Center(child: Text('Error: ...'))`, not a crash. Not
  actually exercised on two real devices this session -- low priority per
  the original ask, flagged here in case Mike wants to confirm it firsthand.

**Mike's interactive Windows verification: done, passed, full Part A-D
checklist closed out** (DBeaver's own `foreign_keys` setting explicitly
not a concern for Mike right now -- skip). Created `nav_discovery_test`
directly in Letos (FK to `domain`, date/link/color/boolean columns, two
seed rows) with Syncthing paused for the test window; F5'd Windows and it
appeared in nav immediately with every column correctly derived (lookup
dropdown resolving to real `domain` names, date/link/checkbox/color swatch
all rendering right) -- Part A's actual promise confirmed working live, not
just in `flutter test`. `field_metadata` display-label override
(`description` -> "Notes") took effect on relaunch. `DROP TABLE
nav_discovery_test` in Letos made it vanish from nav on relaunch, and a
direct query afterward confirmed zero leftover rows across all four
settings tables (`table_column_settings`/`table_view_settings`/
`table_group`/`field_metadata`) -- orphan cleanup verified against the real
db, not just the throwaway-table test suite.

**Real bug found and fixed during this pass, unrelated to discovery
itself:** editing a lookup cell (`domain_id`) in the grid, then opening
that row's edit form right after, showed the *pre-edit* value --
`GenericListScreen._saveCellEdit` only reloaded the screen's cached row
list when the table had a `readOnly` computed field (originally scoped
just to refresh `subscription`'s `yearly_cost`/`next_date`), so every
other table's actions-column edit button kept reading a stale row list
after a cell edit, even though the db write itself succeeded and TrinaGrid's
own cell display updated correctly. Pre-existing, affects all 19 tables
except `subscription`, not something this session's changes introduced --
just the first time it got caught, because this was the first time a
lookup cell got edited in the grid and its form reopened in the same
breath during testing. Fixed by always reloading after a successful cell
edit, not just for readOnly-bearing tables. Confirmed fixed by Mike
immediately after (second Domain edit reflected correctly in the form).

**Part E.1 (batch-1 lookup tables) done, build-verified, not yet
Mike-verified interactively.** `domain`/`priority`/`gender`/`status`/
`quality`/`condition`/`unit`/`importance`/`disposition`/`class` all
retired from `table_configs.dart` onto pure introspection.
`tool/seed_field_metadata_batch1.dart` (one-time, idempotent, already run
against the real db) seeded exactly 2 `field_metadata` rows per table --
`position=255`, `color=#FFFFFF` -- the only two values that had no real
SQL `DEFAULT` in `schema.sql` to fall back to; every other attribute
(labels, `active`'s boolean default, `displayColumn`/`orderBy`) already
matched the introspection heuristics with zero override needed.
`test/batch1_conversion_regression_test.dart` asserts the converted result
against the exact pre-conversion shape for all 10 tables -- all pass.
`table_configs.dart`'s `_lookupConfig` helper and all 10 batch-1
`*Config` constants are gone; `registeredTables` now starts at `person`
(batch 2). `flutter analyze`/`build windows`/`build apk --debug` all clean.

**Part E.2 (batch-2 lookup+FK tables) done, build-verified, not yet
Mike-verified interactively.** `person`/`category`/`time_frame`/
`account_type`/`account`/`supplier`/`shipper`/`shipment`/`journal` all
retired from `table_configs.dart`. Exercised the FK lookup-display-column
logic for real -- every lookup here resolves against the referenced
table's own `name` column, discovered live via `PRAGMA foreign_key_list`,
zero hand-written `LookupConfig` needed for any of them.

**Real bug caught before shipping, found while checking `time_frame`
against its pre-conversion shape:** the discovery service was forcing
`required: false` on *every* lookup field regardless of nullability --
would have silently dropped `time_frame.unit_id`'s required validation
(`NOT NULL`, no default in schema.sql). Fixed: `required` is purely about
nullability now, independent of whether the field is a lookup.

**One genuine architecture decision, surfaced to Mike and resolved before
converting:** `shipment` has no `name` column and no `NOT NULL` column at
all, so `displayColumn`/`orderBy` can't be derived by heuristic the way
every other table's can -- the original hand-written config used `order_id`
and `order_date DESC, id DESC`, neither derivable from introspection.
Chose (Mike's call, from three options) a **reserved `field_metadata`
sentinel convention**: two rows using reserved `field_name` values that
don't refer to a real column --
`(shipment, _display_column, display_label='order_id')` and
`(shipment, _order_by, display_label='order_date DESC, id DESC')` --
checked by `TableDiscoveryService.buildConfig` after the normal heuristics
run, same override-precedence rule as every other `field_metadata` row.
No schema change, stays fully Letos-editable; documented in
`table_discovery_service.dart` as a deliberately narrow, last-resort
mechanism (not a general one) -- `shipment` is the only table needing it
so far. **Worth knowing if Mike ever browses `field_metadata` directly in
Letos:** these two rows for `shipment` look unusual (a `field_name` that
isn't a real column) -- that's expected, not a data error.

`journal` needed zero `field_metadata` overrides at all -- every heuristic,
including `entry_time` as displayColumn and `entry_time DESC` as orderBy
(journal has no `name` column either, but does have a `NOT NULL` `TEXT`
column the fallback heuristic can land on), already reproduced its exact
pre-conversion shape.

Seeded via `tool/seed_field_metadata_batch2.dart` (18 rows across 8
tables, already run against the real db) --
`test/batch2_conversion_regression_test.dart` asserts the converted
result against every hand-written batch-2 config's exact pre-conversion
shape; all 9 pass. `flutter analyze`/`build windows`/`build apk --debug`
all clean; full suite (5 test files, 28 tests) passes together.
`table_configs.dart` now only has `subscriptionConfig` left in
`registeredTables` -- everything else resolves purely through discovery.

**Mike's interactive spot-check of Part E.2: done, passed.** Opened
`Shipment` and `Journal` in the running app -- both looked exactly as
before conversion (display, sort order, columns). Also changed a `Domain`
selection on a `Shipment` record in the grid and confirmed it reflected
correctly in the form view right after -- the stale-row-data fix (see
above) holds for a real lookup edit on a real, already-populated table,
not just the throwaway test table it was originally caught on.

**Part E.3 (`subscription`, the last table) done, build-verified, not yet
Mike-verified interactively.** `table_configs.dart` has no hand-written
`TableConfig` left at all -- `subscriptionConfig` is gone, replaced by
`buildSubscriptionConfig`, an async function that introspects the real
`subscription` table like every other converted table (via the same
`TableDiscoveryService`) and layers on subscription's two genuine
exceptions: the seeded `payment_method_id -> account.code` `field_metadata`
override (`tool/seed_field_metadata_subscription.dart`, one row, already
run), and the `subscription_computed` view (readSource +
`computePreview`, plus the two view-only `yearly_cost`/`next_date`
columns hand-injected at the exact position they held before conversion --
neither can come from `PRAGMA table_info(subscription)`, since they don't
exist on the real table). `registeredTables` is gone entirely --
`table_registry.dart`'s `loadEffectiveTables` now resolves every table
through discovery, with `subscription` as the one named special case.

`test/subscription_conversion_regression_test.dart` proves both flagged
regression risks directly against real, live data, not just structural
assertions: `GenericDao.getAll()` (via the view readSource) returns
`yearly_cost`/`next_date` matching a direct query against
`subscription_computed` for every real row, and the payment-method
lookup's options match `account.code` for every real account row.

**Found and fixed while running the full suite, unrelated to `subscription`
specifically:** `test/widget_test.dart` broke -- not a regression in this
session's work, but a pre-existing fragility finally triggered. It
asserted `find.text('Domain')` unconditionally, assuming `domain` would
always be visible/first; now that nav order is alphabetical (not
batch-1-first) and every table resolves through discovery, `domain`
happens to sit inside Mike's real `PERSONAL` sidebar group, which is
currently collapsed on the real db this test runs against -- and the
rail's `ListView` only builds visible children, so a collapsed-group
table has no `Text` widget in the tree at all, real bug or not. Fixed by
asserting something structurally guaranteed instead ("Settings" always
renders; no error text appeared) rather than one specific table's
visibility, which depends on real, evolving sidebar state the test has no
business asserting against.

39 `field_metadata` rows seeded across the whole Part E conversion (20
batch-1 + 18 batch-2 + 1 subscription), all already applied to the real
db. `flutter analyze`/`build windows`/`build apk --debug` all clean; full
suite (6 test files, 35 tests) passes together.

**Mike's interactive verification of Part E.3: done, passed.** Confirmed
`subscription`'s table view and form view both look correct, including the
calculated fields (`Yearly Cost`/`Next Date`) -- the highest-risk table in
the whole conversion, now fully confirmed on Windows. Next: a fresh
Syncthing backup, resume the paused `essentials_app` sync (paused since
the Windows nav-discovery testing began earlier this session), let it
settle on both MIKE-CU and MIKE-12R, then F5 targeting MIKE-12R for
Android verification of the full conversion.

**Mike's interactive verification on MIKE-12R (Android): done, passed.**
Fresh Syncthing backup taken, sync resumed and given time to settle on
both MIKE-CU and MIKE-12R, then F5'd targeting MIKE-12R -- everything
looked normal. **The entire Table Discovery phase (Parts A-E) is now
verified end-to-end on both Windows and Android**, not just build-verified.

**Follow-up requested at the close of this pass, built same session:
remember each device's last-open table across restarts.** Mike noticed
both platforms always opened to `Account` (alphabetically first now that
nav order comes from discovery, not the old batch-1-first order) instead
of whatever table was open when the app was last closed. Per-device by the
same governing rule as sidebar collapse state (Mike would be annoyed if
one device's last-open table jumped to what a *different* device had open)
-- a new `last_active_table` key in `device_settings`, read/written by two
new `SidebarGroupingDao` methods (`loadLastActiveTable`/
`setLastActiveTable`) alongside its existing collapsed-group state, since
both are "which device is looking at what" nav state. `HomeShell` reads it
once at launch (falls back to the first table in nav order if the saved
one has since been dropped or renamed, same defensive-nav pattern as
everywhere else) and writes it on every `_select`. `flutter analyze`,
`build windows`, `build apk --debug` all clean; new
`test/last_active_table_test.dart` (round-trip, per-device scoping) plus
the full suite (7 files, 38 tests) all pass. **Mike's interactive
verification: done, passed, on both MIKE-CU and MIKE-12R.**

## Table Discovery phase: complete

**Every table -- all 19 original plus anything added directly in
Letos/DBeaver going forward -- now runs through one unified process.**
`table_configs.dart` has no hand-written `TableConfig` left at all;
`subscription` keeps two small, explicitly-documented exceptions
(`subscription_computed` as read source, `computePreview`), nothing else.
This was flagged as a "long-term direction, not this phase's problem to
solve" back in the Settings & Persistence Architecture phase -- it's done
now, verified end-to-end on both platforms, not just aspirational. See
above for the full build history (Parts A-E) and the two real bugs this
session caught before they shipped (stale row data after a grid cell edit
on any non-`subscription` table; a required lookup field silently losing
its required validation).

**Discovery wired into the real nav, not just proven in isolation:**
`HomeShell` now resolves its table list once at launch via
`loadEffectiveTables()` -- for each currently-existing table, a
hand-written `registeredTables` entry wins if one exists (preserves all 19
tables' exact current behavior, including `subscription`'s two exceptions
untouched so far), otherwise it's introspected fresh. This means Part A's
core promise -- a table added directly in Letos already shows up in nav
next launch, no recompile -- is real and working right now, before Part
E's batch conversion even starts. `flutter analyze`, `flutter build
windows`, and `flutter build apk --debug` all clean; full test suite
(`table_discovery_smoke_test.dart`, `table_deletion_handling_test.dart`,
the existing `widget_test.dart`) passes together, 9/9. **Not yet
Mike-verified interactively on either platform** -- next: create a real
throwaway table in Letos, confirm it appears in nav on next launch, per
the session's own verification checklist.

Mike's stated long-term direction (see "Long-term direction" above) is now
active work, not a future goal: `essentials_app` should notice tables
added directly to `essentials.db` (via Letos/DBeaver) without a recompile,
handle tables being removed gracefully, and — the part that makes this
session's scope larger than just the new mechanism — **all 19 existing
hand-written `TableConfig`s get retired onto the same introspection +
`field_metadata` path**, not kept running as a permanent parallel system.
`table_configs.dart`'s current content becomes a one-time seeding source
for `field_metadata`, not a second code path. Two known, deliberate
exceptions carry forward regardless of mechanism: `subscription
.payment_method_id` resolves against `account.code` (not `.name`), and
`subscription`'s list/grid reads from the `subscription_computed` view for
`yearly_cost`/`next_date` (real columns for everything else). Full session
scope and verification checklist live in the instructions doc this session
started from (`code_instructions_table_discovery.md`, Mike's desktop) —
this section will be updated as that work lands, same pattern as every
other phase above.

## Split-Pane Layout session, concluded (build-verified; Mike's interactive verification next)

Built `orders`/`order_items` — the first true parent-child (one-to-many
ownership) pattern in the app, on hold since the "Real-usage findings"
phase until this session. Session instructions doc:
`code_instructions_split_pane.md` (Mike's desktop). Both tables were
already created directly in `essentials.db` via Letos before this session
started, real test data already in place (5 orders, 4-5 items each).

**Part A — confirmed Table Discovery handles both tables, one real gap
found and fixed first.** `orders`/`order_items` use a **new `id`
convention**, different from every table before them — see "New-table
conventions" above for the full rationale (collision avoidance between
offline Windows/Android inserts ahead of a Syncthing sync) and the fix
(`TableDiscoveryService` now matches a literal `id` column by name, not
just `PRAGMA table_info`'s `pk` flag). This wasn't anticipated by the
session's own instructions doc, which only expected the known
`lookup_display_column` gap below — surfaced by inspecting the live schema
before writing any code, flagged to Mike, resolved as "fix discovery, keep
the new id scheme" (Mike's call — the timestamp+random id is deliberate,
now the standing convention for every future table).

Two `field_metadata` overrides seeded (`tool/seed_field_metadata_order_items.dart`,
idempotent, already run against the real db):
- `order_items.order_id` → `lookup_display_column = 'order_number'` — the
  expected gap the instructions doc flagged (`orders` has no `name`
  column), same pattern as `subscription.payment_method_id` → `account.code`.
- `order_items` → `_display_column = 'description'` — not originally
  flagged, found while building: `order_items` has no `name` column and no
  `NOT NULL` column either (`description`/`cost` both nullable), so the
  heuristic alone would fall back to the bare `id`. Same reserved sentinel
  `shipment` already uses (see "Table Discovery phase" Part E.2), not a
  new mechanism.

Also fixed, unrelated to `orders`/`order_items` specifically: `test/widget_test.dart`
had gone stale from real nav growth (past 19 tables) pushing "Settings"
below the fixed test-surface viewport, read as offstage by the default
`find.text` finder even though genuinely rendered — `skipOffstage: false`
fixes it without weakening the assertion. Confirmed pre-existing (failed
identically on a stash of this session's changes, back to plain `HEAD`)
before touching it.

**Part B/C — the split-pane UI and how the app knows `orders` has one.**
`table_configs.dart` still has **no hand-written field list** for either
table — both resolve through plain `TableDiscoveryService.buildConfig`,
same as every table since the Table Discovery phase. `orders` gets exactly
two small, explicit, documented hooks layered on top via
`buildOrdersConfig`, same category as `subscription`'s two exceptions
(`readSource`/`computePreview`), not a return to hand-written per-table
configs:

- `TableConfig.openRowDetail` — opening an *existing* order pushes
  `OrderSplitPaneScreen` instead of the default `GenericFormScreen`.
  Never consulted for "Add" (a brand-new order has no `id` yet to scope an
  items grid to) — that still goes through the plain form, same as every
  other table; the order needs to exist before its items pane makes sense.
- `TableConfig.deleteWarning` — names the real `order_items` cascade count
  before deleting an order (`"This order has 5 items. Deleting it will
  delete them too."`), replacing `GenericListScreen`'s generic "Delete X?
  This cannot be undone." for this one table. Falls back to the generic
  message when the order has zero items — nothing hidden to call out in
  that case.

`OrderSplitPaneScreen` (`lib/screens/order_split_pane_screen.dart`) is the
actual master-detail view — reuses `GenericFormScreen` (order form) and
`GenericListScreen` (items grid) directly rather than a second
implementation, per the instructions doc's explicit ask. One
`LayoutBuilder` switch, same threshold as the nav shell's rail/drawer split
— extracted to `lib/util/layout.dart`'s `wideLayoutBreakpoint` so both
places share one number instead of two independently-maintained constants:

- **Wide (Windows):** `Row` — order form left, items grid right, both live
  simultaneously, no navigation between them.
- **Narrow (Android):** order form full-screen; its AppBar gets one extra
  action (an "Items" button) that pushes a full-screen items list via
  `Navigator`; tapping an item opens its own form; back returns to the
  Order.

Four small, generic, opt-in additions to the shared screens make this
possible without forking them — every one defaults to `null`/current
behavior for the other 20 tables:
- `TableConfig.filterWhere`/`filterArgs` — scopes `GenericDao.getAll` to
  `order_id = ?`, reused for both the wide-mode embedded grid and the
  narrow-mode pushed full-screen list.
- `GenericFormScreen.extraValues` — merged into the write on save, on top
  of the form's own fields, for a real column deliberately not a
  `TableConfig.fields` entry. Only use: the embedded items form silently
  writes `order_id` from the currently-open parent order on insert — Part
  B's explicit requirement that `order_id` is never user-facing inside the
  split-pane, unlike the standalone `order_items` screen's generic FK
  dropdown (Part A's baseline, reached via direct nav, unaffected by any
  of this).
- `GenericFormScreen.popOnSave`/`onSaved` — the wide-layout embedded order
  form saves in place instead of popping (both panes stay live
  side-by-side; a pop would have closed the whole split-pane screen).
  Every other caller (including the narrow-layout order form, which
  behaves exactly like every other table's edit screen) keeps the default
  `true`.
- `GenericFormScreen.appBarActions` / `GenericListScreen.formExtraValues` —
  the narrow layout's "Items" button, and threading `extraValues` through
  from whatever screen opens the form.

`buildOrderItemsConfigForOrder(discovery, orderId)` builds the scoped
items config for both layouts: starts from `discovery.buildConfig
('order_items')` (same as the standalone screen), strips `order_id` out of
`fields` entirely (never a field here, per Part B), and sets `filterWhere`/
`filterArgs`.

**Part D — delete confirmation.** Covered by `deleteWarning` above.
The RESTRICT side (deleting a `supplier` still referenced by an order)
needed **zero new code** — already generic via `GenericDao.delete`'s
existing `StillInUseException` catch, confirmed by the new regression test
below rather than assumed.

**Tests:** `test/order_split_pane_test.dart` (new, 7 tests, read-only
against the real db, never creates/drops/mutates — same approach as
`subscription_conversion_regression_test.dart`) covers the id-by-name
discovery fix, both `field_metadata` overrides, and every
`buildOrdersConfig`/`buildOrderItemsConfigForOrder` hook. Full suite: 8
test files, 45 tests, all passing. `flutter analyze`, `flutter build
windows`, `flutter build apk --debug` all clean.

**Long-term direction, still not this session's problem to solve —
recorded here so it isn't lost, same pattern as how Table Discovery itself
was first flagged as a future goal before it became real work (see "Table
Discovery phase" above):** `orders`/`order_items` still needed one
hand-written special case (`buildOrdersConfig`'s two hooks) to get its
split-pane relationship recognized — the discovery mechanism itself has no
generic concept of "this table is a split-pane parent." The concrete
starting hypothesis recorded when this was first flagged (`code_instructions_split_pane.md`
Part C) is worth restating here so it carries forward: `PRAGMA
foreign_key_list`'s `ON DELETE` action is exactly the signal this needs,
for free — this project has already drawn a clean, deliberate line between
`RESTRICT` (lookup relationship) and `CASCADE` (ownership relationship,
see "Parent-child (one-to-many) relationships" above). A table with an
incoming `CASCADE` FK from another table is very likely a split-pane
parent, the referencing table its child — no new schema convention to
invent, just reading a distinction the project already committed to for
an unrelated reason. Worth someone actually testing this hypothesis
against real cases (right now there's exactly one: `orders`/`order_items`)
before generalizing discovery to build `OrderSplitPaneScreen`-equivalent
UI automatically for any future parent-child pair.

**Windows (MIKE-CU) interactive pass: done, passed.** Opening an order via
the pencil icon shows the order form (left) and its `order_items` grid
(right) live simultaneously — Part B's core promise confirmed working, not
just build-verified. Created a brand-new order, then added new items
against it directly in the split-pane — `order_id` set correctly without
ever appearing as a field, confirmed by inspecting the data in Letos.
Adjusted the divider, navigated away to a different table and back,
closed and reopened the app entirely — the divider position was
remembered both times. Deleted an order with items: the item-count-aware
warning showed, confirming cascaded parent + children both gone.

**Android (MIKE-12R) interactive pass: done, passed — plus one confirmation
beyond the original checklist.** Portrait: order form full-screen with the
"Items" icon, pushing the full-screen items list, back returning to the
order — narrow layout exactly as designed. **Rotating to landscape showed
the full split-pane view, same as Windows** — not explicitly planned for
(the `wideLayoutBreakpoint` check is a plain width comparison, agnostic to
platform or orientation), but confirms the responsive design genuinely
generalizes rather than being Windows/Android-specific. Deleting an order
showed the warning and cascaded correctly there too.

**Orphan check, requested by Mike as a final sanity pass before closing
this session out:** direct query against `order_items` for rows with no
matching `orders.id` (a `LEFT JOIN ... WHERE o.id IS NULL`) — zero results.
`PRAGMA foreign_key_check` clean, `PRAGMA integrity_check` `ok`. Row counts
consistent with everything tested this session (5 orders — the original 4
plus Mike's new one — 20 items total).

**Nav grouping confirmed by Mike:** dragged `Orders`/`Order Items` into a
group like any other table, closed and reopened the app, membership stuck
— the two new tables don't slip through any gap in the (already-proven,
unchanged-this-session) grouping mechanism.

**Real bug caught by Mike's own supplier-delete test — found and fixed
same session, third follow-up, see "Delete handling" above for the full
write-up:** deleting `Amazon` (a `supplier` referenced by `shipment`/
`orders`) showed the plain "Delete "Amazon"? Cancel/Delete" dialog, which
implies deletion might succeed — it can't, a `RESTRICT` FK blocks it every
time. Fixed generically for every table, not just `supplier`:
`GenericDao.findBlockingReferences` checks for a blocking reference
*before* any confirm dialog now; blocked rows get an informational
"Can't delete" dialog instead. **Orphan check re-run after this fix, still
clean** (same query as before: zero `order_items` rows with no matching
`orders.id`).

**Session closed.** Parts A-D built, tested (50 automated tests), and
interactively verified on both Windows and Android, including three
same-session follow-ups (draggable per-device divider; the UNIQUE-column
displayColumn heuristic + `orders.order_number` schema fix; the
check-before-confirming delete-blocker fix, which benefits every table in
the app, not just this session's two). `Order`/
`OrderItem` — on hold since the "Real-usage findings" phase — is done.

**Follow-up, same session, from that first pass — three more items, all
built and verified end-to-end:**

1. **Draggable, per-device divider between the order form and items grid**
   (Mike's ask right after confirming the split-pane itself worked) — a
   `GestureDetector`-driven divider between two `SizedBox` panes (replacing
   the original fixed-50/50 `Expanded` pair), position persisted via
   `ThemeSettingsDao`'s existing generic `device_settings` key/value
   accessor (same mechanism as font size, grid row heights — no new dao).
   **Explicitly per-device, per-table, not per-order** (Mike's clarification)
   — every order on a given device shares one remembered split, keyed by a
   fixed `order_split_pane_ratio` string, not the order's id. Debounced
   500ms, same reasoning as the grid's column-resize save.
2. **`orders` fell all the way through the displayColumn heuristic to the
   bare `id`** — noticed by Mike, not caught during Part A's own baseline
   check. `orders` has no `name` column and (until this fix) no `NOT NULL`
   column either. Mike's suggested fix generalizes past this one table:
   `TableDiscoveryService._deriveDisplayColumn` gained a new heuristic
   step — a single-column `UNIQUE` text constraint (via `PRAGMA
   index_list`/`index_info`, composite unique indexes excluded) now wins
   over the `NOT NULL` TEXT fallback. Paired with the actual schema fix
   this enables: **`orders.order_number` is now `TEXT UNIQUE`** — the live
   table was recreated (SQLite has no `ALTER TABLE ADD CONSTRAINT`),
   confirmed no duplicate `order_number` values existed first, data/FK
   integrity verified after (`PRAGMA foreign_key_check`/`integrity_check`
   clean, all `order_items` rows still resolve to their order). `orders`
   now displays by `order_number` everywhere (grid, delete confirmation,
   nav) instead of the raw id. `schema.sql` updated to match (it never had
   `orders`/`order_items` at all before this — both were created directly
   in Letos, per Part A's own framing, and are now recorded there like
   every other table). New tests for both: `table_discovery_smoke_test
   .dart` (the heuristic, against a throwaway table shaped like `orders`)
   and `order_split_pane_test.dart` (the real `orders.order_number`
   constraint and resulting displayColumn).
3. **Delete confirmation implied success was possible when a `RESTRICT`
   reference made it structurally impossible** — see "Delete handling"
   above (in the batch-1 design section) for the full write-up;
   `GenericDao.findBlockingReferences` + `GenericListScreen._delete`'s
   check-before-confirming fix applies to every table, not just the
   `supplier` case Mike found it with. New `test/blocking_references_test
   .dart` (3 tests, real data — `supplier` blocked by `shipment`/`orders`,
   an unreferenced `domain` row reports no blockers, `order_items` never
   appears as a blocker for `orders` since it's `CASCADE`).

Full suite: 50 tests, all passing; `flutter analyze`, `flutter build
windows`, `flutter build apk --debug` all clean.

## ID Primary Key Conversion session, concluded

Converted `journal`/`shipment`/`subscription` onto `orders`/`order_items`'
timestamp+random `id` scheme — see "id convention changed" above for the
full technical write-up (the table-rebuild procedure, per-table migration
scripts in `essentials_app/migrations/`, and the verification checklist:
row counts, `integrity_check`, `foreign_key_check`, byte-for-byte row
diffs, `subscription_computed` re-verified, Table Discovery confirmed
generic already, RESTRICT spot-checked, one real Dart fix
(`GenericDao.insert()` now returns the real `id`, not `Database.insert()`'s
raw rowid — covered by a new test exercising both id schemes directly).

**Real-world complication, mid-session, not part of the original plan:** a
second Syncthing empty-db-propagation incident (MIKE-12R's stale,
pre-conversion copy became an empty stub once sync was unpaused, and
overwrote the Windows master copy) — hit, diagnosed, and recovered
same-session. Full write-up under "Sync architecture" above, including
what's still not fully explained (the existing root-cause fix from the
first incident should have prevented a silent stub this time; it didn't,
leading hypothesis is a zero-byte-file race during the sync window, not
confirmed) and the procedural mitigation to use going forward (let Syncthing
report "up to date" on both devices before launching the app after
unpausing). One real, permanent loss: Mike's own manual verification rows
added on Windows before the corruption — not recoverable, accepted as
low-stakes.

**Grid number formatting, unrelated cleanup requested the same session:**
the `id` column (`lib/screens/generic_list_screen.dart`'s `_buildColumns`)
was relying on `TrinaColumnType.number()`'s default `'#,###'` format,
comma-grouping the new ~16-digit ids into something unreadable — given its
own explicit ungrouped format (`'0'`). `cost`/`yearly_cost` (`FieldType
.real` columns generally) went through two iterations before landing
right: first stripped of grouping entirely per an initial ask, then
corrected back to grouped-with-fixed-2-decimals
(`'#,##0.00;-#,##0.00'`, explicit positive/negative pattern) once Mike
clarified only `id` should ever have been ungrouped.

**Final state, both devices confirmed byte-identical:** `journal` (299
rows), `shipment` (25), `subscription` (14) all on the new `id` scheme,
`integrity_check`/`foreign_key_check` clean, existing ids unchanged,
`flutter analyze`/`flutter test` (52 tests) clean. Commits landed
per-table (`journal`, `shipment`, `subscription`, the `GenericDao.insert()`
fix, two formatting commits) rather than one bundled commit, per this
project's established pattern.

**Not yet done, deliberately deferred, not urgent:** a literal Letos-GUI
insert test with `id` genuinely omitted (done instead via direct SQL,
functionally equivalent) and a second RESTRICT spot-check specifically
*after* the recovery/restore (done once, before the corruption; the
schema is unchanged so this is very likely still fine, just not re-proven
a second time). Worth closing out opportunistically, not worth a dedicated
session.

## Syncing at the Record Level session, Parts A-D concluded (operational follow-ups remain, see "Open items")

Full technical write-up under "Syncing at the Record Level" above — this
is the chronological pointer entry. Parts A (standalone prototype) and B
(server + firewall) both done and verified. Part C (wiring the real app)
done and live-verified end-to-end against the real, built Windows app and
the real server: four real bugs found and fixed along the way, none of
them visible from static analysis or the unit test suite alone —
`sqlite_crdt`'s soft-delete rewrite defeating SQLite's own RESTRICT/
CASCADE, the id scheme needing `PRIMARY KEY` instead of `UNIQUE`, a
`DatabaseHelper` concurrency race causing a real crash on first launch,
and a genuine `sqlparser` bug silently dropping a column named `key`.
Every fix backed up, migration-tested against a disposable copy first,
and verified against the real `essentials.db` (`integrity_check`/
`foreign_key_check` clean throughout, real row counts unchanged).

Also settled this session, not originally scoped: the Letos/DBeaver
workflow going forward (no record-level edits, schema changes need
manual all-copies coordination, add-column planned as an in-app feature,
delete-table/delete-column staying deliberately manual) — see "Letos/
DBeaver workflow going forward" above. `field_metadata`'s edit workflow
is the one open item there, unresolved.

**MIKE-12R wired and Part D's core test done, same session, continued
past the original stopping point:** real bidirectional sync confirmed
over the actual network between real MIKE-CU and real MIKE-12R hardware
— a row created on one appeared on the other via live push, a delete
correctly tombstoned on both. One real gotcha caught and fixed along the
way (pushing MIKE-CU's file byte-for-byte to MIKE-12R also copies its
node id, which would have silently broken future propagation to that
device — fixed with `SqliteCrdt.resetNodeId()`, the library's own
purpose-built method for exactly this situation), and one real,
non-code finding (MIKE-12R's connection doesn't survive the screen
sleeping/app backgrounding — ColorOS battery optimization, not a sync
bug; confirmed by isolating it with the screen held awake, and still
needs the battery-optimization exemption set on the phone before relying
on this day-to-day).

**RESTRICT/CASCADE verified on real entity data, same session, and a
genuinely serious bug caught doing it:** `GenericDao.delete()`'s cascade
lookup called back into the parent `SqliteCrdt` from inside its own
transaction — `sql_crdt` documents this as a guaranteed deadlock, and
nothing before this had actually exercised the path (not the Part A
prototype's hand-written version, not the unit tests). The first real
delete of an `orders` row with real `order_items` hung solid for 30
seconds and timed out — would have hung the app indefinitely in
production, silently, the first time anyone deleted an order with items.
Fixed (pass the transaction's own `txn`, not the parent `crdt`),
re-verified clean: real delete, real cascade, correct propagation to
MIKE-12R over the real network.

**WAL interaction checked deliberately, same session — a real correction
to a long-standing operational habit, not just a clean bill of health:**
the manual checkpoint-before-trusting-a-copy discipline, load-bearing
under whole-file Syncthing sync, does **not** apply to the sync
mechanism itself anymore — record-level sync reads live via SQL, which
sees WAL-resident data same as checkpointed data by design. Confirmed
directly: wrote a row with no checkpoint before or after, confirmed via
file mtime/size it genuinely stayed WAL-only, confirmed the real server
received it anyway. The discipline still fully applies to anything that
reads the file directly instead of through SQL (Letos, DBeaver, `adb
pull`, plain file-copy backups) — learned concretely, not abstractly,
when an earlier verification pass this same session missed a real
propagated row because it only pulled the main `.db` file, not its
`-wal` companion.

**Real off-`HOMExf`-entirely-then-reconnect test done, same session —
Parts A through D all complete.** Mike took MIKE-12R off wifi entirely,
added a real journal entry through the app's own UI while genuinely
offline, turned wifi back on: confirmed via the server log that it
flushed automatically, no manual trigger, no force-close. One real
robustness gap surfaced along the way (not a failure of this specific
test, a genuine finding): the first merge attempt failed on a foreign
key (an artifact of the server having just been wiped clean for test
isolation, combined with MIKE-12R correctly not re-uploading lookup data
it didn't create), and recovery depended on MIKE-12R's connection
happening to cycle again rather than any guaranteed retry — `crdt_sync`
has no retry-after-merge-failure mechanism.

**Two of the session's "Open items" closed out immediately afterward,
same session, not deferred:** Mike set MIKE-12R's battery-optimization
exemption, then it was re-verified properly rather than just trusted —
locked the screen, confirmed via `dumpsys power` it was genuinely
`Dozing`, pushed a live change from MIKE-CU, confirmed it arrived and
merged while the phone stayed asleep the whole time with zero
disconnects (the exact scenario that reliably killed the connection
before). And the merge-failure-retry gap just found got fixed the same
way it was found — not left as a documented risk: `SyncService` now
forces a periodic disconnect+reconnect (every 5 minutes) so a fresh
handshake regularly re-evaluates and resends anything the server never
actually acknowledged, turning the incidental recovery above into a
deliberate, bounded one. Verified with a deterministic two-node
reproduction of the exact failure shape, not just reasoning about it.

What's left after all of that is genuinely operational follow-up, not
more test work — see "Open items" (`field_metadata`'s edit workflow,
the planned add-column screen, server auto-start, and untested
MIKE-LP/MIKE-WP onboarding). Commits landed per logical checkpoint
throughout (prototype findings → server → migrations → data-layer
rewrite → live-verification bug fixes → MIKE-12R wiring → CASCADE
deadlock fix → periodic-reconnect fix), not one bundled commit, per
this project's established pattern.

**Two more "Open items" closed out, same session:** Mike chose
`field_metadata`'s edit workflow first — built `FieldMetadataScreen`
(see "Letos/DBeaver workflow going forward" above) rather than any
Letos-based approach, since a Letos edit would silently never sync
under the new record-level model. Then server auto-start: a
Startup-folder shortcut launching a compiled executable, initially as a
visible-but-minimized console window (Mike's explicit choice, over
Task Scheduler, for the reasons in "Open items" above). Mike then asked
for a system tray icon instead of the taskbar window — rebuilt as a
three-process chain (`launch_tray_hidden.vbs` → `tray_host.ps1`
NotifyIcon host → `server.exe` as its hidden child), verified via the
process tree that nothing has a `MainWindowHandle` and that the server
is still genuinely listening and logging. Full detail in "Open items"
above.

**Third "Open item" closed out, same session:** the add-column screen
— `SchemaEditorService` + `AddColumnScreen`, reached from Settings.
Generates and runs a validated `ALTER TABLE ... ADD COLUMN` on this
device only (same "trigger it again on every other device" model as the
rest of schema-change handling), with a live DDL preview and a
copy-to-clipboard success dialog for applying the same statement to the
server's `hub.db` by hand. Full detail in "Open items" above. That
leaves only untested MIKE-LP/MIKE-WP onboarding, deliberately deferred
by Mike until the app has seen more real usage.

**Fresh real end-to-end re-verification, same session, after all three
"Open items" above landed:** F5'd `essentials_app` on both MIKE-CU and
MIKE-12R against the now-tray-hosted server. Added a `shipment` record on
MIKE-CU — arrived on MIKE-12R. Added a `journal` record on MIKE-12R —
arrived on MIKE-CU. Both directions "pretty quick," Mike's words. Proves
the tray-host relaunch (a different process wrapper around the identical
`server.exe`) didn't regress real sync, and that the new
`FieldMetadataScreen`/`AddColumnScreen` additions this session didn't
touch the data path — real bidirectional record-level sync confirmed
working on real hardware, not just inferred from the code being
unchanged.

## Debugging session, concluded

Mike using the app for real (per "Real-usage findings" above) surfaced
four real bugs, found and fixed one at a time as Mike reported them, each
verified by Mike on both Windows and Android before moving to the next —
not a test pass Code drove.

**1. Settings' font-size slider made the app permanently unrecoverable —
a real, reproducible Flutter behavior, not a bad-data issue.**
`ThemeController.themeData` scaled the whole `TextTheme` via
`base.textTheme.apply(fontSizeFactor: ...)`. Reproduced in isolation
(a standalone `flutter test` calling the exact same code): on this
Flutter version, `ThemeData().textTheme` has **`fontSize: null` on every
style** — real sizes only get merged in later, per-locale, when the
`Theme` widget itself calls `ThemeData.localize` (English gets
`typography.englishLike`, CJK `dense`, Farsi `tall`). Calling `.apply()`
with a non-1.0 `fontSizeFactor` against a style whose own `fontSize` is
still null trips `TextStyle.apply`'s assertion — confirmed this crashes
for *any* font size other than the theme's default (14), regardless of
font family, and confirmed the fix (merging in
`base.typography.englishLike` before scaling) resolves it while
preserving correct scaled sizes. This is why it looked unrecoverable:
the bad size was already persisted to `device_settings`, so it crashed
on every subsequent launch too, including a rebuild — fixed structurally
(the getter no longer produces a bad `TextTheme` for *any* size), not by
clearing data.

**2. Wrap-text and column-width changes reverted on table switch or app
exit — but held while just viewing the table.** `GenericListScreen`
debounces grid-state saves 600ms after the last change (see
"1. Table view persistence" above), and both `_reload()` (table switch)
and `dispose()` (leaving the screen) cancelled that pending timer
without flushing it — a change made inside the 600ms window was silently
dropped, never written. Fixed by flushing the pending save immediately
before cancelling in both places.

**3. Fixing #2 immediately surfaced a second, pre-existing bug in the
same save path — the exact `sqlite_crdt` soft-delete/`UNIQUE` gotcha
already documented above under "Live end-to-end verification" (Part C),
now hitting real internal DAO code instead of a rare business-data
collision.** `saveColumnSettings` deleted every row for the table+device
then re-inserted the full set — worked the *first* time a table+device
ever saved (nothing to collide with), then threw
`UNIQUE constraint failed: table_column_settings...` on the very next
save, because `sqlite_crdt` rewrites `DELETE` into a tombstone
(`is_deleted = 1`), not a real removal, so the "deleted" row was still
physically occupying its unique slot when the fresh `INSERT` ran. This
had likely been silently breaking every second-or-later grid-settings
save since the feature was built — #2's fix just made saves actually
happen reliably enough to expose it via a visible uncaught exception
instead of quietly vanishing. Fixed by switching to `INSERT OR REPLACE`
per column (matching `SqliteCrdtHelpers.upsert`'s existing pattern) plus
a `column_name NOT IN (...)`-scoped delete for genuinely stale columns —
see the updated note under Part C above for the general rule this
confirms.

**4. `id` and the actions column's position/frozen state didn't persist
either — found by Mike moving `id` to the end and freezing the actions
column to the start, on both platforms.** These two were hardcoded
first/last and explicitly excluded from `_persistGridSettings` as
"structurally fixed" (see the now-updated doc comment on
`GenericListScreen`) — but TrinaGrid already lets the user drag/freeze/
hide them exactly like any other column, so the exclusion was just an
unfinished corner of #2/#3's fix, not a separate design decision.
Generalized: both now persist width/order/frozen/visible the same as any
`TableConfig.fields` column, defaulting to their original first/last
spots only when nothing's been saved yet.

**Two smaller, unrelated requests handled the same session:**
- Grid scrollbar thickness bumped from TrinaGrid's default (8.0) to 12.0
  (1.5x) — read as too thin to grab comfortably.
- Every `TextFormField` in `GenericFormScreen` set to `maxLines: null`
  (auto-wrap/grow) instead of the default single line — Mike's ask, "all
  fields on any form view should auto wrap." Side effect worth knowing:
  Enter/Return in these fields now inserts a newline instead of doing
  nothing, since a multi-line field can't distinguish "submit" from
  "next line" the way a single-line one implicitly does.

Committed in two batches: the `AddColumnScreen`/tray-host work from the
previous ("Syncing at the Record Level") session, which had landed on
disk but was never actually committed, as its own commit first; then
this session's four fixes plus the two smaller requests as a second.

## Debugging session, continued: six grid features and a real sync bug

Same calendar session as above, continued well past the point it was
first marked "concluded." Six real features added to `GenericListScreen`
in sequence, each verified on both Windows and Android before moving to
the next, followed by a genuine `sql_crdt` sync bug found through Mike's
own real usage (not a test pass) and root-caused for real rather than
patched around.

### Copy record

Straightforward, per Mike's spec: a Copy button (standard copy icon)
next to Add, creating a new record pre-filled from whichever row the
grid's current cell sits in (TrinaGrid's own single-click-selects-a-cell
model — same "selected" notion as everywhere else in this grid), `id`
excluded, "No record selected." if nothing's selected.
`GenericFormScreen` gained a `copyFrom` parameter, mutually exclusive
with `existing` — seeds every field's value the same way editing does,
but `isEditing` stays false so Save inserts rather than updates. The
selected row is looked up by `id` from the last-rendered row list, not
reconstructed from the grid's own cells — same reasoning as the actions
column's edit/delete handlers (a boolean cell holds `1`/`0`, a null text
cell holds `''`). For tables with `TableConfig.openRowDetail` (`orders`),
copy always opens the plain form, not the split-pane detail — duplicating
`order_items` along with the parent was never the intent.

### Row grouping ("Group by this column")

TrinaGrid ships this natively (`TrinaRowGroupByColumnDelegate`) — the
work was wiring it up, not building it. "Group by this column"/"Ungroup"
added to the column menu (same spot as the existing "Wrap text"), one
column at a time (picking a new one replaces the old, doesn't stack).
Persisted per-device in a new `group_column` field on
`table_view_settings` — same reasoning as sort/filter already being
per-device. Two real bugs found immediately by Mike actually using it,
both fixed the same session:

- **Every custom cell renderer crashed on a group-summary row.** TrinaGrid
  calls a column's `renderer` for group rows exactly like real ones, but
  a group row has no real `id`/data cells — the actions column's
  id-based row lookup, the boolean checkbox, and the color-field renderer
  all needed an explicit `row.type.isGroup` bailout added first.
- **`Ungroup` crashed — a real bug in `trina_grid` itself,** not ours:
  `setRowGroup(null)` sets the delegate to null and then immediately
  `assert(hasRowGroups)`s on the very next line, guaranteed to fail
  every time in debug builds. Worked around with an empty-columns
  delegate instead of `null` — `TrinaRowGroupByColumnDelegate` already
  treats `visibleColumns.isEmpty` as "disabled" by design, so this needed
  no downstream changes, just switching the "Ungroup" menu item's
  visibility check from `hasRowGroups` (delegate non-null, which now
  never happens again) to `enabledRowGroups`.

Also found: wrapped text silently stopped working the moment a table was
grouped. The old approach used TrinaGrid's per-row `setRowHeight`, which
indexes into `stateManager.refRows` directly — once grouped, that list
holds only the group-summary rows, not the real rows nested inside each
group's `children`. Fixed by switching row height to a single grid-wide
style default (`TrinaGridStyleConfig.rowHeight`, toggled between normal
and wrapped) instead of a per-row override — every row falls back to it
identically whether grouped or not.

### Filter by value (lookup columns)

TrinaGrid's own "Set filter" popup — confirmed by reading
`FilterHelper.filterPopup`'s source — hardcodes a plain text value field
for every column regardless of type, no per-column override point. For a
lookup column (Journal's Status, say) that means typing the underlying
FK id, not the display text the grid shows. Added "Filter by value..."
to the column menu for lookup columns specifically: a dropdown of the
actual display options (the same `lookupMaps` already loaded for cell
display, no extra query), translating the pick to an exact-match id
filter via `TrinaGridStateManager.setColumnFilter` under the hood. The
stock "Set filter" stays available alongside it, untouched, for anything
this doesn't cover (combining with other columns, non-lookup fields).

### Footer aggregates ("Set column footer...")

Another built-in TrinaGrid feature (`TrinaAggregateColumnFooter` —
sum/average/min/max/count), wired up via a "Set column footer..." dialog
on integer/real columns. Persisted per-device as a new `aggregate` field
on `table_column_settings`. One real mechanical wrinkle: unlike
wrap-text, this couldn't work through a `setState` rebuild —
`TrinaGrid` only ever consumes its `columns`/`rows` constructor params
once, at first mount, so a freshly-rebuilt `footerRenderer` would just be
discarded. Fixed by mutating `footerRenderer` directly on the *live*
column object `stateManager` already holds (a plain mutable field, same
as `width`/`hide`/`frozen`), then calling `stateManager.notifyListeners()`
directly — the documented way to force a repaint after changing
something TrinaGrid has no setter for. The footer's own `numberFormat`
is read from the column's own type rather than left at the widget's
default (`#,###`, no decimals), so a currency-like `cost` column's sum
doesn't round to a whole number while every cell above it shows cents.

Same session, per Mike's ask: every plain integer/real column (not
lookup ids, not the `id` column itself) right-aligned via a new
`_numericTextAlign` helper, with the footer's own alignment pinned to
match.

### Export to CSV

New toolbar icon next to Restore Defaults. Deliberately hand-rolled
rather than using `trina_grid`'s own `TrinaGridExportCsv` — that reads
raw cell values (would export lookup FK ids instead of display text) and
iterates `refRows` only (would silently drop every row once a table's
grouped, same `refRows`-vs-nested-children pitfall as the wrap-height bug
above). Exports exactly the current view: active filter and sort
respected, grouping flattened back to plain rows regardless of
expand/collapse state, formatted display values (not raw), hidden
columns and the actions column skipped.

One real dependency snag: `file_picker`'s latest stable (11.0.3) fails to
build on Android with this project's AGP 9.0.1 — `cannot find symbol:
class FilePickerPlugin` — because stable predates a fix
("Removed explicit Kotlin Gradle Plugin (KGP) application ... to resolve
warnings under AGP 9.0+", `file_picker`'s own changelog) that only
landed in the `12.0.0-beta` series. Pinned to `12.0.0-beta.7` (matching
the new required `saveFile()` signature, `fileName`/`bytes` now
required) rather than stable, noted in a pubspec comment to revisit once
a stable release picks up the fix.

### Row coloring ("Use Color")

The color field's actual intended use, per Mike: "Use Color" on a
table's own color field, or on any lookup field (every lookup target
already has its own `color` column, confirmed by Mike directly), makes
every cell in that record use the corresponding color for its text,
except hyperlinks. Settled through discussion before building:

1. **Mutually exclusive, one source at a time** — same shape as
   `group_column`, a single `row_color_column` field on
   `table_view_settings`, not a per-column boolean needing its own
   enforcement logic.
2. **Per-device, not shared** — Mike's call, and a deliberate exception
   to how `field_metadata`'s other flags (`is_link`, etc.) work: which
   column looks good as a row-color source, or whether to use one at
   all, can genuinely differ by device.
3. **Mostly free, technically.** Lookup/date/`id` columns have no custom
   renderer, so they already pick up TrinaGrid's built-in
   `rowTextStyleCallback` with zero extra work. Only the wrap-aware text
   renderer and the color-field renderer's own text needed to explicitly
   consult the resolved row color, since both bypass TrinaGrid's default
   rendering entirely. Boolean cells have no text to color; the link
   renderer was left untouched on purpose.

`GenericDao.getLookupOptions` switched from selecting just
`valueColumn`/`displayColumn` to `SELECT *`, so a lookup target's own
`color` column comes along for free without a second query — read
opportunistically by field-coloring logic, absent gracefully if a future
lookup table doesn't have one.

### The real bug: `sql_crdt`'s watermark is global, not per-table

Found through Mike's own usage, not a test: edited several `status`
colors on Windows: never showed up on Android (MIKE-12R) even after
closing and reopening the app repeatedly. Root-caused properly rather
than assumed:

- Pulled MIKE-12R's actual `essentials.db` via `adb pull` (same
  discipline as the Part D empty-db incident) and confirmed the colors
  genuinely never arrived, ruling out a stale-screen theory.
- Server log showed it correctly identifying and re-offering the same
  outstanding `status` changeset on every reconnect, but MIKE-12R's
  local copy never advanced — not a connectivity flake (confirmed with
  the app in the foreground the whole time, no disconnect logged).
- Replayed the exact merge SQL (`INSERT ... ON CONFLICT DO UPDATE ...
  WHERE excluded.hlc > table.hlc`) by hand against a pulled copy of
  MIKE-12R's database with Mike's real data — it worked correctly,
  ruling out a bug in the merge logic itself.
- Temporary diagnostic logging (a `print()`-to-file tee in `main.dart`,
  since Android's logcat buffer rotated past crdt_sync's own
  exception-printing before it could be pulled) plus a from-scratch
  reading of `sql_crdt`'s `_getLastModified` finally found it: the sync
  watermark each device reports is `SELECT MAX(modified)` unioned
  **across every table**, not tracked per table.

This app's per-device grid settings (`table_column_settings`/
`device_settings`) write very frequently — every resize, wrap toggle,
footer choice, filter change, all the features above. If one of those
lands with a *later* timestamp before some other, slower-moving table's
pending edit has synced, the global watermark races past it — and once
that happens, the peer's "send me anything newer than my watermark"
request permanently excludes the older change. Confirmed directly: a
*fresh* re-edit of one status row (a new, later timestamp) synced
immediately, while the untouched older edits stayed stuck exactly as
predicted. Not something the existing periodic-reconnect fix (see
"Debugging session" above) papers over — the underlying data really is
"too old" relative to the watermark, forever, no amount of retrying
changes that.

**Fix:** a custom `ChangesetBuilder` (`safeChangesetBuilder`, duplicated
into both `SyncService` and the server the same way `schema.sql`'s
statements are already duplicated into `server.dart`'s
`schemaStatements` — separate Dart packages, can't share a file) that
drops the watermark (`modifiedAfter`) entirely for the one-time
catch-up pull crdt_sync makes on every (re)connect, sending the complete
current dataset instead of a filtered delta. Safe and cheap: `sql_crdt`'s
own merge is an idempotent, hlc-compared upsert — a resend of
already-applied data is a same-row no-op, confirmed directly — and this
app's whole dataset is small enough on a local network that resending
everything every reconnect (currently every 5 minutes) is negligible.
The narrower, targeted *live* push path (a single just-made local edit)
is untouched, exactly as narrow as the library's own default — there's
no watermark to get stuck there.

### That fix immediately surfaced a second, unrelated problem

Making the catch-up pull send *everything* meant every reconnect now
included `table_column_settings` in the same all-or-nothing merge
transaction — and MIKE-12R's copy of that table was still missing the
`aggregate` column from the footer-aggregates work above (confirmed via
the same diagnostic logging: `SqliteException: table
table_column_settings has no column named aggregate`). One missing
column poisoned the entire batch, silently rolling back everything in
it, `status` included. Checking further, MIKE-12R was actually missing
**three** columns: `aggregate`, plus `group_column` and
`row_color_column` from grouping and row-coloring above — none of the
"still needs this on MIKE-12R" follow-ups from this session had
actually been done yet.

Getting them applied hit its own dead end: MIKE-12R's SQLite browser
("SQLite Pro") appeared to edit an internal copy rather than the live
file — schema changes showed correctly in its own view immediately
after running them, then silently vanished (reverted, not persisted)
once the database was closed there ("Delete" in its UI, which just means
disconnect, not delete the file — confusing labeling, cost real time
here). Confirmed by pulling the live file via `adb` directly after each
attempt and finding the column still missing every time, no matter what
SQLite Pro's own UI showed. Also ruled out along the way: Syncthing
silently reverting the edit — a real, once-true concern for this exact
folder (a leftover `.stversions`/sync-conflict trail proved it *used to*
be shared), but Mike confirmed no device has an essentials_app folder
configured in Syncthing anymore, so that wasn't it this time.

Resolved by bypassing the GUI tool entirely: pulled MIKE-12R's live
`essentials.db` + `-wal` via `adb`, checkpointed the WAL locally
(`PRAGMA wal_checkpoint(TRUNCATE)`) so the file was self-contained, ran
the three `ALTER TABLE` statements with a local `sqlite3`, confirmed
`PRAGMA integrity_check` and real row counts, then `adb push`ed the file
back to the exact same path and deleted the now-stale `-wal`/`-shm`
files on-device so nothing would try to replay old frames against the
new file. Verified end to end afterward: all seven `status` colors
matched Windows exactly, and Mike independently confirmed "Use Color" on
two different columns (Status on Windows, a different lookup — Who — on
MIKE-12R) each persisted correctly and independently through a close/
reopen on both devices, per the per-device design above.

**Also cleaned up while in there:** two genuinely leftover artifacts in
MIKE-12R's `Databases/essentials_app` folder from before it was
unshared from Syncthing — a `.stfolder.removed-*` marker and the whole
`.stversions` backup directory (old sync-conflict copies) — deleted:
neither serves any purpose now that record-level sync is the only
mechanism touching that folder.

Committed in two batches, given how deeply interleaved the six features
turned out to be within `GenericListScreen` (built incrementally across
one long session, not worth retroactively untangling into six perfect
commits): the grid features together first, then the sync fix (plus the
server-side schema catch-up that rode along in the same file) second.
