# Essentials v2 — `image` Field Format: Design

**Session date:** 2026-09-03
**Status:** Design, not yet built. Supersedes the `attachment` sketch in `claude/essentials-v2-architecture.md`'s "File / Attachment Sync" section and `claude/essentials-v2-phase2-design.md`'s `attachment` entry — those described a generic file-attachment field; this is narrower and simpler, images only.
**Companion docs:** `claude/essentials-v2-architecture.md` (Deferred list, "File / Attachment Sync"), `claude/essentials-v2-phase2-design.md` (`attachment`, dropped from Phase 2), `claude/essentials-v2-file-transfer-endpoint-design.md` (the hub endpoint this field's sync depends on), `claude/essentials-v2-image-field-ui-design.md` (the actual widget — capture, drag-and-drop, preview)
**Not yet assigned a phase number.** Same status the deferred `attachment` work had: designed, not scheduled.

---

## Summary

One new field format, `image`. One storage rule, no branches:

**An image gets into the field exactly two ways — camera capture, or copy/drag-and-drop in — and both land in the same place, the same way.** There is no "sometimes managed, sometimes just a path" split. That split existed in earlier drafts of this design (distinguishing camera-captured images from a "pick an existing file" mode that behaved like `link_file`) and was deliberately cut as unnecessary complexity — confirmed 2026-09-03. If someone wants an unmanaged reference to a file they don't want a copy of, that's what `link_file` and `url` are for; those two formats are untouched by this design and keep their existing, separate, not-synced behavior.

Every image the field holds is a copy, owned by the app, synced like any other CRDT-tracked data — just with the actual bytes traveling through a dedicated file-transfer channel instead of a database row, since CRDT rows aren't the right shape for multi-megabyte binaries.

---

## What's stored in the field

The row's `image` column holds one string: a **relative key**, not an absolute path —

```
{table}/{record_id}/{field_name}/{filename}
```

Same value, byte-for-byte identical, in every device's copy of the row (it's an ordinary CRDT-synced TEXT column, no different from any other field). What differs per device is how that key gets turned into an actual file on disk — each device resolves it against its *own* local files-root at render time. That local translation step is the whole reason a relative key was chosen over an absolute path: an absolute path baked in at capture time (`C:\Users\Mike\...` or `/data/user/0/...`) would only ever be correct on the device that wrote it, which is precisely the failure mode `link_file` deliberately accepts and this field deliberately doesn't.

No scheme prefix (`attachment://` or similar) is needed — with only one storage contract for this field, there's nothing to disambiguate against. `link_file`/`url` values never appear in an `image` column, so nothing downstream has to guess which kind of string it's looking at.

---

## Where the bytes actually live, per device

**Local write, at capture/drop time (every device, immediately, offline-safe):**

**Correction, 2026-09-03, after reading `lib/db/database_helper.dart` directly:** an earlier draft of this section proposed Android app-private storage (`path_provider`) specifically to avoid "re-entangling with the old Syncthing folder." That reasoning doesn't hold up against the actual code — `DatabaseHelper._androidDirectory` (`/storage/emulated/0/Databases/essentials_app`) is still `essentials.db`'s real, live path today; only Syncthing's *watch* on that folder was removed, not the folder itself, and the app already holds the `MANAGE_EXTERNAL_STORAGE` permission needed to write there (`_ensureAndroidStoragePermission`, granted and verified on MIKE-12R). Introducing a second, different storage convention (`path_provider`'s app-private directory) for this one field would be new complexity for no real benefit — mirroring the existing, already-proven `_windowsDirectory`/`_androidDirectory` convention is simpler and needs no new dependency:

- Windows (including MIKE-CU acting as hub): `C:\Databases\essentials_app\files\{table}\{record_id}\{field_name}\{filename}`
- Android: `/storage/emulated/0/Databases/essentials_app/files/{table}/{record_id}/{field_name}/{filename}` — same directory `essentials.db` itself lives in, same permission already gated on app start, no new permission handling needed for this feature.

**Canonical copy on the hub (MIKE-CU), once uploaded:**

**Correction, 2026-09-03, after reading `server/bin/server.dart` directly for the endpoint design below:** `hub.db` does not live at `C:\Databases\essentials_app\`; it's at `C:\Databases\essentials_app\server\hub.db` (`server.dart`'s own `dbDir`/`dbPath` constants) — a deliberately separate file from MIKE-CU's own client-side `essentials.db` (see architecture doc, "server keeps its own separate `sqlite_crdt` replica... not a shared handle to the real `essentials.db`"). So the hub's canonical file store follows that same split, under the hub's own directory: `C:\Databases\essentials_app\server\files\{table}\{record_id}\{field_name}\{filename}`. MIKE-CU's own Flutter app instance (rendering its own Form view) keeps a *separate* local cache at the client path from the table above (`C:\Databases\essentials_app\files\...`, next to its own `essentials.db`) — the same "two files with overlapping content on MIKE-CU's disk" trade-off already knowingly accepted for the database itself.

This hub-side store is the durable, always-on copy every other device can pull from — the hub-and-spoke topology already proven for CRDT sync, extended to file bytes instead of rows. This is the piece that makes it Memento-Cloud-shaped rather than Memento's-broken-Sheets-path-shaped: the hub actively transfers bytes on request, nothing relies on a link resolving on trust. See `claude/essentials-v2-file-transfer-endpoint-design.md` for the endpoint itself.

**Every other spoke, on first need:** pulls from the hub lazily (see "Sync mechanism" below) and caches at the same relative key under its own local files-root from the table above.

---

## Entry methods

**1. Camera capture.** A camera icon in Form view (Form view only — this field has no grid/list rendering in scope, matching the "preview in Form view only" requirement). Tapping it opens the device camera via `image_picker` (new dependency — nothing in `pubspec.yaml` today opens a camera; `file_picker` only picks existing files). On a device with no camera (MIKE-CU, a desktop), this icon degrades the same way `barcode` already does on Windows — hidden or disabled cleanly, not a dead button.

**2. Copy-in / drag-and-drop.** Desktop: drag an image file onto the field (needs `desktop_drop` or equivalent — genuinely new, nothing in the codebase handles native drag-and-drop today) or paste from clipboard. Mobile: whatever the platform's native "insert image" affordance is (share-sheet target, or a gallery picker via `image_picker`'s non-camera mode). Either way, the source file's bytes are copied into local managed storage immediately — the original file the user dragged in is never referenced by path afterward.

Both methods converge on the same next step: write to the local files-root path above, write the relative key into the field's value, queue the file for upload to the hub.

---

## Preview

**Form view only**, per the requirement — no grid/list thumbnail column in this design (mirrors the existing `Card`/gallery view being separately deferred; if that view ever gets built, it's the natural place for a grid-level thumbnail, not this field format).

Render as `Image.file(...)` against the locally-resolved path (relative key + this device's files-root). Three states:

- **File present locally** — show it.
- **Row has a key but the file hasn't synced to this device yet** (just pulled a CRDT update referencing an image captured elsewhere) — show a placeholder/spinner, kick off the hub pull, swap in the real image when it lands.
- **Empty field** — the camera icon / drop target itself, no image yet.

---

## Sync mechanism

Extends the already-scoped-but-unbuilt hub file-transfer endpoint (`server/bin/server.dart` — confirmed by reading it, 2026-08-23, no file/upload route exists). Full endpoint design: `claude/essentials-v2-file-transfer-endpoint-design.md`. Shape:

1. Device captures/drops an image → writes locally → uploads to the hub's endpoint, keyed by the same relative key.
2. Other devices learn a new `image` value exists the normal way — it's just a CRDT row field, synced over the existing WebSocket like any other column.
3. On rendering that field, a device checks whether it already has a local file at the resolved path; if not, pulls it from the hub over the file-transfer endpoint and caches it.

**Lazy pull, not eager push** — a device only fetches bytes for images it's actually asked to render, not everything captured on the other 3 devices. This matters more now than it would have with just MIKE-CU/MIKE-12R: with 4 devices eventually, eager full replication means every device's disk holds every photo ever taken on any of the other three, whether or not it's ever looked at that record.

---

## New dependencies

- `image_picker` — camera capture + gallery/mobile picker
- `desktop_drop` (or equivalent) — Windows drag-and-drop target
- Hub file-transfer endpoint in `server/bin/server.dart` — new route(s), doesn't exist yet

## Open items, not yet decided

- **Delete behavior** — when a record (or just the image field's value) is deleted, does the file get deleted from the hub and every spoke's cache, or tombstoned like CRDT rows are? Orphaned files if not handled.
- **Concurrent edit** — two devices setting the same field's image at the same time is a plain CRDT LWW resolution at the row level (whichever write has the later HLC wins), but that leaves the *loser's* uploaded file orphaned on the hub with nothing pointing at it. Needs a cleanup pass or acceptable-to-ignore judgment call.
- **File size limits** — none discussed yet; camera-original photos can be several MB each, worth deciding whether to downscale/compress on ingest before it becomes a real disk-usage problem across 4 devices.
- **Content-addressing** — keying by `{table}/{record_id}/{field_name}/{filename}` (as inherited from the old `attachment` sketch) versus a content hash. Hash-keying would dedupe identical images and make the "which file does this row actually need" question trivial, at the cost of an extra lookup layer. Not resolved — current design keeps the simpler path-based key.
