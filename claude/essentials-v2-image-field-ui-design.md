# Essentials v2 — `image` Field: UI Design (capture, drop-in, preview)

**Session date:** 2026-09-03
**Status: DONE, 2026-09-03, real-device verified on MIKE-CU and MIKE-12R.** All six build order steps below shipped and confirmed working end to end: captured a real photo on MIKE-12R (Camera button), confirmed it appeared on MIKE-CU (Windows app, pulled via `FileSyncService.fetch`) -- byte-identical file confirmed on both the hub's canonical store and MIKE-CU's local cache, `6955388` bytes, `diff` clean. See `claude/essentials-v2-architecture.md`'s "Known Systemic Risks" section, occurrence 6, for the one real hiccup hit along the way (not a bug in this feature -- the pre-existing `crdt_sync` new-table-creation race, recovered with the existing `tool/adopt_migrations.dart`).
**Companion docs:** `claude/essentials-v2-image-field-design.md` (storage/sync model this UI writes into), `claude/essentials-v2-file-transfer-endpoint-design.md` (the hub endpoint `FileSyncService` calls), `claude/essentials-v2-phase2-design.md` (`FieldFormatHandler` pattern this follows)

This is the last of the three docs for this feature — storage model, hub endpoint, and now the actual widget. Together they're a complete, buildable design.

---

## `FieldFormatChoice` entry

```dart
image('image', 'Image'),
```

A genuinely new stored format (not a shared-`value` variant like `url`/`color`) — same category as `link_file`/`currency`/`rating`/`button`. `options: {}`, nothing configurable in v1 (no size limits, no "allow multiple" — this is a single-image field, matching the storage doc's one-relative-key-per-field model).

---

## Two-handler split — following the `button` precedent exactly

`button` already established the pattern this needs: **a format whose form-field needs more than the shared `FieldFormatHandler.buildFormField(context, field, controller)` interface can pass** (table name, record id) gets special-cased directly in `GenericFormScreen._buildField`, *before* the generic handler dispatch — the registered handler's own `buildFormField` becomes unreachable dead code, kept only because the interface requires an implementation. `image` needs exactly the same thing `button` needs (table name + record id — here, to build the relative storage key `{table}/{record_id}/{field_name}/{filename}`), so it gets the same treatment:

- **`ImageFormatHandler`** (new, `lib/util/field_formats/image_format_handler.dart`) — registered in `FieldFormatRegistry` for **grid column only**, mirroring `ButtonFormatHandler` line for line: `readOnly: true`, `renderer: (_) => const SizedBox.shrink()`, no actual per-row content. This is where the earlier storage-design doc's "Form view only, no grid thumbnail" decision actually gets enforced — the grid column exists purely because every registered format needs one, not because this field renders anything there.
- **`GenericFormScreen._buildImageField`** (new method, alongside the existing `_buildButtonField`) — the real widget, special-cased in `_buildField` the same way: `if (field.format == 'image') return _buildImageField(field);`, checked before `_formatHandlerFor` dispatch.

---

## The "record doesn't exist yet" problem — same one `button` already has, same answer

`button` is disabled on Add (`onPressed: id == null ? null : ...`) because running a `button_clicked` script needs a real row id to bind to. The image field has the identical structural problem: the relative storage key needs `record_id`, and on Add, no row exists yet — `widget.existing` is null, there is no id.

**Chosen: same answer as `button` — disabled until the record is saved once.** Consistent with the "simplest way possible" preference already stated for this feature, and it's the precedent already sitting in this exact codebase rather than a new pattern introduced just for this field. The image field's capture/drop affordances render visibly but inactive on Add (greyed out, a tooltip like "Save the record first, then add an image"), and become live once `widget.existing` is non-null — same `id == null ? null : ...` gate `_buildButtonField` already uses.

**Alternative considered, not chosen:** pre-generating the row's id client-side (matching the `CAST(unixepoch('now','subsec')*1000 AS INTEGER)*1000 + (abs(random())%1000)` scheme every business table's `id` DEFAULT already uses) before the Add form even opens, so a real id exists to key the file path against from the start, and passing it explicitly on insert instead of relying on the column DEFAULT. This would let capture work during Add too — genuinely more capable, but it's new machinery (every other Add flow today lets SQLite's own DEFAULT mint the id, confirmed by `GenericDao.insert()`'s doc comment) for a benefit ("attach a photo before the first Save") that's easy to work around by just saving first. Worth revisiting only if the disabled-on-Add experience turns out to be a real friction point in practice, not designed in from the start.

---

## Entry methods, per platform

Same "different affordance per platform, degrade cleanly rather than fake a lowest-common-denominator" precedent `barcode` and the Geo Location capture button already established (`Platform.isAndroid`/`Platform.isWindows` gates, not a single cross-platform widget pretending both platforms are the same).

**Android — camera capture or gallery pick, both via `image_picker` (new dependency):**
- Camera icon → `ImagePicker().pickImage(source: ImageSource.camera)`
- A second "choose existing" icon (photo-library glyph) → `ImagePicker().pickImage(source: ImageSource.gallery)` — this is the mobile-side answer to "copied into the field" from the simplified spec: picking an existing photo already on the device.
- Needs `Permission.camera` requested first for the camera path — same `permission_handler` call already used by `BarcodeFormatHandler._scan`, same "show a SnackBar and bail if denied" handling, no new permission-handling pattern.

**Windows — drag-and-drop or browse, no camera (desktops don't have one):**
- A `DropTarget` (new dependency: `desktop_drop` — nothing in this codebase does native OS drag-and-drop today; this is the one genuinely new *interaction* this feature introduces, not just a new format) wrapping the preview area. Drop a file → `onDragDone` hands back the dropped path(s); take the first, verify it's a recognized image extension (`jpg`/`jpeg`/`png`/`heic`/`webp` — same list the hub endpoint's content-type map uses) before treating it as a valid drop, ignore/snackbar-reject otherwise.
- A "Browse..." icon using `file_picker` (already a dependency, already used identically by `LinkFileFormatHandler` for exactly this "pick a file from disk" job) as the non-drag-and-drop path — covers both "copied into" (browse to a file the user copied somewhere) and gives Windows users an affordance that doesn't require a working drag gesture.
- No camera icon on Windows at all — same "no icon at all, not a greyed-out one" rule `barcode` already established for its own Windows behavior, not a new call.

---

## What happens on capture/drop — the local write

1. Source bytes land as a `File` (from `image_picker`'s result, `desktop_drop`'s dropped path, or `file_picker`'s picked path) — one `File` object regardless of which of the four entry points produced it, so everything past this point is unified.
2. Compute the destination directory: `{platform files root}/{table}/{record_id}/{field_name}/` — `{platform files root}` is `C:\Databases\essentials_app\files` (Windows) or `/storage/emulated/0/Databases/essentials_app/files` (Android), per the storage design doc's corrected paths, mirroring `DatabaseHelper._windowsDirectory`/`_androidDirectory` exactly rather than introducing a separate convention.
3. **Delete any existing file(s) already in that directory first** — a field holds exactly one image; replacing it (recapture, drop a different file) shouldn't leave the old one behind as an orphan on the *local* disk (the hub-side/other-devices' copies of the old file are a separate, already-flagged open item — see the storage doc's "Concurrent edit"/orphan-file items, unchanged by this).
4. Copy the source bytes in as `image.<ext>` (extension taken from the source — camera capture is typically `.jpg`, a dropped/picked file keeps its own). Fixed filename, not the original picker-supplied name — keeps the directory single-item and predictable, and side-steps ever needing to sanitize an arbitrary OS filename into a URL path segment (the endpoint design's path-traversal validation still applies regardless, but a fixed, app-chosen filename removes an entire class of "what did the OS actually hand us" edge cases).
5. Write the relative key (`{table}/{record_id}/{field_name}/image.<ext>`) into the field's `TextEditingController` — this is what actually gets saved to the row on form Save, same as every other format's controller-driven save path.
6. Fire `FileSyncService().upload(...)` (see the endpoint design doc) — not awaited by the UI; the preview already has the bytes locally (step 4), so the upload is a background concern. Failure is swallowed-and-logged the same way `FileSyncService.upload` already specifies, relying on the next successful reconnect rather than a bespoke retry here.

---

## Preview widget

Lives inside `_buildImageField`'s returned widget, above the capture/browse/drop row, inside the same `InputDecorator`-with-label shape `RatingFormatHandler.buildFormField` already established for a non-`TextFormField` form field:

- **Local file exists at the resolved path** (the common case right after capture, or on the device that originally added it) — `Image.file(file, fit: BoxFit.cover)` in a fixed-size box (e.g. 160×160 — small enough not to dominate the form, matching this field's "Form view only, not a gallery" scope).
- **Field has a value but no local file yet** (a device that just synced the row but hasn't pulled the bytes) — a placeholder box with a spinner, and a one-shot `FileSyncService().fetch(...)` call from `initState`/on first build for that field; swap to the real `Image.file` once it resolves, fall back to a broken-image icon on a 404/failure (matches the endpoint doc's "404 is an expected outcome, not an alarm" framing — the UI's job is just to show that plainly, not treat it as an error state).
- **Field is empty** — the capture/browse/drop row itself is the only content; no placeholder box needed (nothing to preview yet).

An additional small "remove image" affordance (X icon on the preview, when non-empty) clears the controller's text — the actual file-deletion-on-clear question is the storage doc's already-flagged open "delete behavior" item, not resolved here; clearing the field's *value* is independent of whether the now-orphaned file on disk/hub ever gets cleaned up.

---

## New dependencies to add

- **`image_picker`** — Android camera capture + gallery pick. (Windows support in this package is limited/inconsistent across versions — not relied on here; Windows uses `desktop_drop`/`file_picker` instead, per the platform split above. Worth a quick pub.dev check at implementation time for the currently-recommended version, same "spike before pinning" discipline `barcode`'s `mobile_scanner` choice already followed, rather than guessing a version number in this doc.)
- **`desktop_drop`** — Windows drag-and-drop target. Genuinely new interaction pattern for this codebase; confirm at implementation time that it builds cleanly on Windows (same `flutter build windows` check `mobile_scanner`'s spike already did for its own package) before committing.
- **`file_picker`** — already a dependency, reused as-is (no version change needed).
- **`permission_handler`** — already a dependency, reused as-is for `Permission.camera`.

---

## `options` JSON

```json
// image
{}
```

Nothing configurable in v1 — no max dimensions, no compression setting, no "allow multiple images" toggle. Matches `link_file`/`barcode`'s own "options is always `{}`, nothing configurable yet" minimalism.

---

## Build order (within this feature, once scheduled to a phase)

Mirrors the discipline every phase design doc here already follows — prove the riskiest new mechanism first, in isolation, before wiring the full field:

1. ~~**Hub file-transfer endpoint**~~ — **DONE.** `PUT`/`GET`/`HEAD` built in `server/bin/server.dart`, verified against an isolated scratch harness, then for real against the live hub after restart (real round trip, correct content-type, clean atomic-write behavior).
2. ~~**`FileSyncService`**~~ — **DONE.** `upload`/`fetch` in `lib/db/file_sync_service.dart`, plus `DatabaseHelper.resolveFilesDirectory()`. Path-resolution logic verified by an isolated test; the real upload/fetch path proven in step 6 below.
3. ~~**`ImageFormatHandler` + `FieldFormatChoice.image` entry**~~ — **DONE.** Grid-column-only registration mirroring `ButtonFormatHandler`, zero changes needed to `AddFieldScreen`.
4. ~~**`GenericFormScreen._buildImageField`**, Android path~~ — **DONE.** Camera + gallery via `image_picker`, disabled-until-saved gate, three-state preview widget.
5. ~~**Windows path**~~ — **DONE.** `desktop_drop` drag-and-drop (whole field as the target, hover-highlighted) + `file_picker` browse, both funneling through a shared extension-validation step Android's pickers don't need.
6. ~~**Real-device verification**, both directions~~ — **DONE, 2026-09-03, real hardware, real hub, not simulated.** Captured on MIKE-12R via the Camera button; confirmed showing on MIKE-CU after `FileSyncService.fetch` pulled it. Verified server-side too, not just visually: the photo (`6955388` bytes) is byte-identical (`diff` clean) on the hub's canonical store (`C:\Databases\essentials_app\server\files\...`) and MIKE-CU's own local cache (`C:\Databases\essentials_app\files\...`), at exactly the relative-key path the storage design specifies. One real hiccup along the way, unrelated to this feature's own code: the throwaway test table's creation hit the pre-existing `crdt_sync` new-table-creation race (architecture doc, "Known Systemic Risks," occurrence 6) — recovered with the already-existing `tool/adopt_migrations.dart`, no new fix needed.
