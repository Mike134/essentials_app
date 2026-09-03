# Essentials v2 — Hub File-Transfer Endpoint: Design

**Session date:** 2026-09-03
**Status:** Design, grounded in a read of the live `server/bin/server.dart` and `lib/db/migration_service.dart` / `lib/db/sync_service.dart` — same discipline every other design doc here follows. Not built.
**Companion docs:** `claude/essentials-v2-image-field-design.md` (the field format this exists to support), `claude/essentials-v2-architecture.md` ("File / Attachment Sync" — original aspirational sketch, superseded by this), `claude/essentials-v2-image-field-ui-design.md` (the client, `FileSyncService`, that calls these routes)

---

## What already exists to build on

`server.dart` is plain `dart:io` `HttpServer`, not `shelf` — a raw `await for (final request in server)` loop that checks `request.uri.path` for a couple of special-cased plain-HTTP routes before falling through to `crdt_sync_server.upgrade(...)` for the WebSocket protocol. There's already exactly one precedent for this shape: **`GET /migrations`** (`_handleMigrationsGet`), added specifically because `crdt_sync`'s own batch-atomicity gap meant some things can't safely go through the WebSocket channel at all — see server.dart's own comment on why it's a "side-channel that doesn't depend on the schema already matching."

The file-transfer endpoint is a second instance of that same pattern: image bytes have no business going through `crdt_sync`'s changeset mechanism (it's built for row-level SQL merges, not multi-megabyte binaries), so it gets its own plain-HTTP routes on the same port, same server, same `await for` loop, checked before the `crdt_sync_server.upgrade` fallback — exactly where `/migrations` is checked today.

Client-side, `lib/db/migration_service.dart`'s `fetchFromServer()` is the precedent to mirror: resolve the hub's address via `SyncService.resolveServerAddress(crdt)` (the same helper already used for the WebSocket connection), open a plain `HttpClient`, hit the hub over HTTP, `try`/`catch` with a log-and-continue on failure (never blocks app usage — `SyncService`'s own retry loop covers reconnection).

---

## Routes

Three routes, all under `/files/`, keyed by the same relative key the `image` field design already settled on: `{table}/{record_id}/{field_name}/{filename}` — 4 URL path segments after `/files/`.

### `PUT /files/{table}/{record_id}/{field_name}/{filename}` — upload

Body: raw image bytes. No JSON envelope — same "just send the bytes" simplicity the rest of this app avoids over-engineering.

Server writes to `C:\Databases\essentials_app\server\files\{table}\{record_id}\{field_name}\{filename}`, creating intermediate directories as needed (mirrors `main()`'s existing `Directory(dbDir).createSync(recursive: true)` at startup).

**Write to a temp file, then rename, not a direct write.** A `GET` for the same key arriving mid-upload must never see a partial file — same class of concern this project has already been burned by once (the empty-stub `essentials.db` incidents were exactly "a reader observed a file mid-write"). Write to `{filename}.upload-tmp`, `File.rename()` to the final name only after the write completes — `rename` on the same volume is atomic, no reader ever observes a partial file under the real name.

`PUT`, not `POST` — uploading the same key twice (a retried upload after a dropped connection, or a device re-sending after reconnect) is idempotent overwrite-with-the-same-or-newer-bytes, which is what `PUT`'s semantics are for; no need to invent a "does this already exist" check first.

Response: `200 OK` on success, empty body. `500` with the error message on any write failure (disk full, permissions, etc.) — logged server-side the same way every other handler here just prints.

### `GET /files/{table}/{record_id}/{field_name}/{filename}` — download

Server checks whether the file exists at that path; if so, streams it back (`request.response.addStream(file.openRead())`) with `ContentType` inferred from the extension (a small extension→MIME map is enough — this field is images only, so it's `jpg`/`jpeg`/`png`/`heic`/`webp` at most, not a general-purpose MIME registry). `404` if not present — an ordinary, expected outcome (a device asking for an image it doesn't have cached yet is exactly the lazy-pull path this whole design exists for), not an error to alarm on.

### `HEAD /files/{table}/{record_id}/{field_name}/{filename}` — existence check

Same routing, no body either direction — `200` or `404` only. Lets a device check "does the hub already have this" without pulling the full bytes, for the case in `image_picker`. Also worth a `GET` with `Range` support -- **deliberately not built in v1.** Its natural producers exist on both ends (uploading device wants to confirm the hub actually has it before considering the local write "synced"; a device could in principle skip a redundant re-upload if the hub already has the key) but neither of the two consumers described above is required for the design to work end-to-end, so this is listed as a possible follow-on refinement, not part of the initial build.

---

## Path-traversal validation

`record_id`, `field_name`, and especially `filename` all originate from client-controlled data (a filename dragged in from the OS, or one `image_picker`'s camera capture assigns). None of them should be trusted as literal path segments without checking first — `../../../windows/system32/whatever` in a `filename` segment is exactly the kind of thing that needs rejecting before it ever reaches `File(...)`, regardless of this being a personal LAN-only deployment (the existing Windows Firewall rule scopes *who* can reach port 1340 at all, but that's not a substitute for validating what a legitimate-looking request is allowed to do once it's in).

Validation, applied to each of the 4 path segments individually before use: reject any segment that is empty, is exactly `.` or `..`, or contains `/` or `\`. `request.uri.pathSegments` already splits on `/` for the parse, so the remaining check is just "no segment resolves to a traversal token and none smuggles a second path separator" — cheap, and enough, since the four segments are then joined back together under a fixed, hardcoded root (`server/files/`) rather than ever being handed to the filesystem as a single unvalidated combined string.

`table` and `field_name` are additionally checkable against `field_definitions`/`table_definitions` (they should already exist as real schema entities) — worth doing as a belt-and-suspenders check, though the path-segment validation above is the actual security boundary, not this lookup.

---

## Client-side (`FileSyncService`, new — mirrors `MigrationService`'s shape)

```
lib/db/file_sync_service.dart
```

- **`Future<void> upload(String table, String recordId, String fieldName, String filename, File localFile)`** — called right after the local write at capture/drop time (per the `image` field design's "write locally first, offline-safe" step). `PUT`s the bytes to the hub via `SyncService.resolveServerAddress`. On failure (hub unreachable), swallow and log, same as `fetchFromServer()` — no retry queue in v1; the next successful `SyncService` reconnect is the natural retry point, matching how `MigrationService.fetchFromServer()` already piggybacks on reconnects rather than maintaining its own retry timer.
- **`Future<File?> fetch(String table, String recordId, String fieldName, String filename)`** — called from the `image` field's Form-view preview widget when the resolved local path doesn't exist yet. `GET`s from the hub, writes to this device's own local files-root (same temp-then-rename discipline as the server side), returns the resulting `File`, or `null` on 404/failure (preview widget shows its placeholder state either way).

Neither method needs to be wired into `SyncService`'s own connect/reconnect lifecycle the way `MigrationService.fetchFromServer()` is — uploads are triggered by user action (capture/drop), and downloads are triggered by render (a Form view actually showing that field). No blanket "sync all pending files on every reconnect" pass in v1, consistent with the `image` field design's "lazy pull, not eager push" choice.

---

## What this doesn't solve (carried over from the `image` field design's open items)

- **No delete route.** Nothing here removes a file from the hub or a spoke's cache when a record/field value is cleared or the record is deleted. Needs a `DELETE /files/...` route and a client-side trigger, once the "delete behavior" open item in the `image` field design is actually decided (tombstone vs. hard delete vs. leave-orphaned-and-GC-later).
- **No dedup / content-hash.** Two devices independently capturing visually-identical photos get two separate keys and two separate stored copies — the path-based key from the `image` field design doesn't dedupe. Listed there as an open item, not resolved here either.
- **No size cap enforced.** A multi-hundred-MB `PUT` body would be accepted as readily as a 200KB one. Fine for a personal LAN deployment at today's usage; worth a limit before this gets exercised by 4 devices' worth of camera-original photos.
