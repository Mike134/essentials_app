> **Synced copy.** This file mirrors the claude.ai Project doc of the same name (Project: "Essentials"). The claude.ai Project is where I keep it updated across chat sessions; this repo copy is what Claude Code and any local tooling should read and trust for execution. Keep both in sync going forward: when either copy changes, update the other in the same session.

---

# Essentials v2 — Phase 2: Rich Field Types

**Session date:** 2026-08-23
**Status:** Design, grounded in a read of the live codebase (`lib/`, `schema.sql`, `pubspec.yaml`, `server/bin/server.dart`) — same discipline Phase 1's design followed. **Scope confirmed 2026-08-23** — see "Confirmed decisions" below.
**Companion docs:** `claude/essentials-v2-architecture.md`, `claude/essentials-v2-phase1-design.md`, `claude/essentials-v2-phase1-handoff.md`

---

## Confirmed decisions (2026-08-23, before handoff to Claude Code)

Three things this design surfaced as real product judgment calls, not implementation detail — confirmed before any implementation started, same "confirmed" gate Phase 1 used for its clean-slate directive and FK approach:

- **`attachment` is dropped from Phase 2 entirely**, not shipped local-only as this doc originally recommended. Mike wants sync working before attachments are usable at all — a field that silently doesn't sync between MIKE-CU and MIKE-12R was judged not worth shipping half-built. Attachments (local storage *and* hub file-transfer sync) become one future phase, designed and built together. The `attachment` section below is kept as reference for when that phase is designed, but **it is out of Phase 2's build order** — see the revised build order.
- **`formula` ships as originally recommended** — the small arithmetic expression subset (see below), not full JS. Confirmed acceptable.
- **Model tier: Opus for the formula expression evaluator, Sonnet for everything else in Phase 2.** Matches the Phase 1 handoff's own flag that formula evaluation was the one plausible candidate for a stronger model; every other Phase 2 format (new `FieldFormatHandler` implementations, UI screens) is mechanical follow-through comparable to what Sonnet already handled in Phase 1.

---

## Summary

Phase 1 built the engine: `table_definitions`/`field_definitions`, dynamic DDL, and a `format` string that's pure metadata over an always-TEXT column. Phase 2 is where that pays off — but the architecture doc's format table (`rating` through `rollup`) was written before any of this code existed, and reading the actual `AddFieldScreen`/`GenericFormScreen`/`GenericListScreen` changes two things about it:

1. **`lookup`/`rollup` don't belong in Phase 2.** Both require a `link_record` field pointing at another table's row (not just `select`'s FK-to-lookup-table pattern) — that's the Features Roadmap's own Phase 4 ("Cross-Table Linking"). Phase 2 should not build them; doing so would mean building Phase 4's linking model early and informally, then redoing it. **Correction to the architecture doc's format table**, same spirit as Phase 1's corrections to it.
2. **The render path has a scaling problem Phase 2 will hit immediately if it isn't addressed first.** See "Key decision" below — this is the one piece of actual design work Phase 2 needs before any new format is added, not optional polish.

Everything else — `number`/`currency`/`percentage`, `rating`, `url`, `barcode`, `formula`, and inline-mode `select` — is genuinely Phase 2's job, at varying levels of risk (mapped out below). `link_file` and `attachment` were both originally scoped for Phase 2 (`link_file` low-risk, `attachment` local-only); `link_file` stays in, `attachment` was pulled out entirely per the confirmed decision above.

---

## What the code already does (verified by reading it)

| Capability | Where | Phase 2 relevance |
|---|---|---|
| `format` is metadata-only; every field is physically TEXT | `field_definitions`, `SchemaEditorService.addField` | Confirmed still true, no exception needed for any Phase 2 format — even `attachment` (stores a path/filename, not a BLOB) and `formula` (stores nothing itself, computed at read time) fit this. |
| Format catalog for the UI | `FieldFormatChoice` enum (`lib/util/field_format_choice.dart`) | `text, integer, real, boolean, date, dateTime, select` only. This enum is the thing Phase 2 extends. |
| Format → runtime shape | `SchemaRegistry._buildField`/`_formatToFieldType` (`lib/db/schema_registry.dart`) | Collapses every format to a 6-value `FieldType` enum (`lib/models/table_config.dart`) plus two booleans (`isLink`, `isColor`) already bolted onto `FieldConfig`. **This is the scaling problem — see below.** |
| Per-field grid rendering | `GenericListScreen._buildFieldColumn` (`lib/screens/generic_list_screen.dart`, ~1780 lines) | Switches on `field.type`/`isLookup`/`isLink`/`isColor` at four separate call sites (column building, cell value parsing, save-value extraction, and the "editable" gating list). Confirmed by grep — every one of Phase 1's 6 formats already needs a touch point in each. |
| Per-field form rendering | `GenericFormScreen._buildField`/`_currentValues` (`lib/screens/generic_form_screen.dart`) | Same pattern, smaller file (~470 lines) but the identical shape: one `if` per format, in two methods. |
| Add Field UI | `AddFieldScreen` (`lib/screens/add_field_screen.dart`) | Already has the one branch Phase 1 needed (`select`'s linked-table/on_delete sub-form). Adding N more formats each needing their own options sub-form is straightforward to bolt on the same way, **if** each format's options shape is nailed down first (this doc does that below). |
| File picking | `pubspec.yaml`: `file_picker: 12.0.0-beta.7` | Already a dependency — used today for CSV import (per `project-overview.md`'s "New Table Checklist"/CLAUDE.md references). Reusable as-is for `attachment`/`link_file` pickers; no new package needed for picking. |
| Hub file-transfer endpoint | `server/bin/server.dart` | **Does not exist.** Grepped for `file`/`attachment`/`upload`/route handlers — nothing. The architecture doc's "File / Attachment Sync" section is aspirational, not built. This matters for scoping `attachment` below. |
| Scripting engine (`flutter_js`) | `pubspec.yaml` | Not a dependency yet — reserved for Phase 5 per the roadmap. This matters for scoping `formula` below. |
| Barcode/camera package | `pubspec.yaml` | Not a dependency yet. Nothing to build on for the `barcode` format yet — genuinely greenfield. |

---

## Key decision: stop widening `FieldType`, add a per-format handler

### The problem, stated concretely

Phase 1 shipped 6 formats (7 counting `select`'s two flag add-ons). Each one already required a touch point in `FieldType`'s switch in `SchemaRegistry`, plus 3–4 touch points each in `GenericListScreen` and `GenericFormScreen` — roughly 15–20 call sites total for 6 formats. Phase 2 proposes **9 more** (`number`(revised)/`currency`/`percentage`/`rating`/`url`/`barcode`/`formula`/`attachment`/`link_file`, plus inline `select`). Extending the same pattern means roughly tripling the branch count in two files that are already 1780 and 470 lines. That's not a hypothetical scaling concern — it's the literal shape of what's already there, confirmed by reading it, not assumed.

It also cuts against the architecture doc's own stated north star: "format is a presentation and input hint, not a storage constraint... changing a field's format is metadata-only." That's true at the database layer today. It stops being true in spirit at the UI layer the moment adding a format means editing two giant screen files instead of registering something self-contained.

### The fix

Introduce one small interface, and route **only new Phase 2 formats** through it — Phase 1's 6 formats keep their existing `FieldType`-based code paths untouched (no regression risk, no rewrite of code that already works and is verified on real hardware):

```dart
/// One implementation per Phase-2-and-later format. Registered by format
/// string in FieldFormatRegistry, looked up once at the top of
/// GenericListScreen's/GenericFormScreen's existing per-field methods --
/// each becomes "if there's a handler for this format, delegate; otherwise
/// fall through to the existing FieldType switch," not a parallel rewrite.
abstract class FieldFormatHandler {
  String get format; // matches field_definitions.format / FieldFormatChoice.value

  /// Grid column for this field -- same return shape GenericListScreen's
  /// per-format branches already build.
  TrinaColumn buildGridColumn(FieldConfig field, BuildContext context);

  /// Form input widget for this field.
  Widget buildFormField(FieldConfig field, FieldFormState state);

  /// Raw stored TEXT -> typed value for editing/computation.
  Object? parseStoredValue(FieldConfig field, String? stored);

  /// Typed value -> TEXT for writing back (every column is TEXT, always).
  String? serializeForStorage(FieldConfig field, Object? value);
}
```

`FieldFormatRegistry` is a flat `Map<String, FieldFormatHandler>` built once at app start (`main.dart`, alongside the existing theme/DB setup). This is deliberately not a bigger refactor — `FieldConfig`/`TableConfig` keep their exact current shape (per Phase 1 design's own "keep `TableConfig` as the runtime shape... only its source changes" rule, now applied one layer up). The only new thing `FieldConfig` needs is a nullable `format` string it doesn't already carry explicitly (today it only survives as the input to `_formatToFieldType`, then gets thrown away) — plumb the raw `format` string through to `FieldConfig` so the registry lookup has something to key on.

**Why this belongs in Phase 2 and not later:** doing it now costs one small interface and touches the two screens' entry points once. Deferring it to Phase 3+ means the same fix has to happen after the branch count has doubled again with view-type-specific rendering layered on top.

---

## Format catalog for Phase 2

Each entry: storage shape, `options` JSON, widget, and anything that's a real risk vs. routine work.

### `number` (revises `integer`/`real`)

`FieldFormatChoice` deliberately didn't collapse `integer`/`real` into one `number` format in Phase 1 ("deliberately not guessed at ahead of this screen" — see that enum's doc comment). Now that a screen exists to design it against: **keep `integer` and `real` as distinct formats** (they already work, already have distinct keyboards/parsing, and collapsing them buys nothing — the architecture doc's `number` format's only real feature, a display mask, is separable). Add `options: { decimals: int? }` to `real` (default 2) purely as a display hint for the grid's existing `TrinaColumnType.number(format: ...)` call — no new format, no new storage rule, no `FieldFormatHandler` needed (folds into the existing `FieldType.real` path in both screens with one new options read).

### `currency`

New format. Storage: TEXT holding a plain decimal string (`"19.99"`), same as `real` — never store the symbol or thousands separators in the cell. `options: { symbol: string (default '$'), decimals: int (default 2) }`. Grid: `TrinaColumnType.number(format: '$symbol#,##0.00')`, mirroring the existing `real` column-type call almost exactly. Form: same numeric `TextFormField` as `real`, with a `prefixText: symbol` decoration. Low risk — this is a `FieldFormatHandler` whose `parseStoredValue`/`serializeForStorage` are just `double.tryParse`/`toString()`, identical to what `real` already does inline.

### `percentage`

New format. Storage: TEXT holding the raw fraction as a decimal string (`"0.15"` for 15%), not the display integer — matches how `TrinaColumnType.percent`-style formatting normally expects its input, and keeps the stored value directly usable by a future `formula`/`rollup` field without a hidden ×100 or ÷100 step depending on which format reads it. `options: { decimals: int (default 0) }`. Form: numeric input with a `suffixText: '%'`; the input widget should multiply by 100 for display and divide by 100 on save (documented clearly in the handler, since this is the one format where displayed text and stored text are deliberately not the same number — worth a code comment flagging it explicitly, the same way Phase 1 flagged non-obvious conventions).

### `rating`

New format. Storage: TEXT holding a plain integer string (`"4"`). `options: { max: int (default 5) }`. Form: a row of tappable star icons (`Icons.star`/`Icons.star_border`), no new package — plain `IconButton` row, same complexity class as the existing color-picker's popup. Grid: read-only star rendering is a `CellRenderer` (TrinaGrid supports custom cell renderers — confirm the exact API name against the pinned `trina_grid: ^2.2.2` version before implementing, not assumed) or, if that turns out to be more friction than it's worth for a first cut, a plain "4/5" text cell with the full star widget only in the form. Low risk either way.

### `url`

**Not a new stored format at all.** `SchemaRegistry._buildField` already reads `options['isLink'] == true` off *any* field's options, regardless of format (`lib/db/schema_registry.dart:157`) — `FieldConfig.isLink` is already fully wired through both screens (blue underline + open-in-browser icon in the form, tappable-link cell rendering in the grid, per the grep results above). All Phase 2 needs is to expose `url` as its own entry in `FieldFormatChoice` for discoverability in `AddFieldScreen`'s picker, where selecting it just sets `format: 'text'` with `options: {isLink: true}` under the hood — zero new render code, a few lines in `AddFieldScreen._buildOptionsJson`. Worth documenting this clearly in `FieldFormatChoice`'s doc comment so a future reader doesn't go looking for a `url` case in `SchemaRegistry` that was never meant to exist.

### `link_file`

New format, but low risk — architecture doc's distinction from `attachment` (stores a path/URL string, app doesn't own or manage the file, not synced) means this is almost `url`'s twin: TEXT storage, `options: {}` (nothing needed yet), a text input with a "Browse" button using the already-present `file_picker` dependency to fill in an absolute path, and an "Open" affordance that shells out to the OS (`url_launcher`, already a dependency, handles `file://` URIs). No new package, no sync concern (explicitly out of scope per the architecture doc), no file-ownership bookkeeping. Good candidate to build first — proves the `FieldFormatHandler` pattern end-to-end on the lowest-risk format before tackling `attachment`.

### `attachment` — dropped from Phase 2 (confirmed 2026-08-23), kept here for reference

The architecture doc's file-sync design (hub server file-transfer endpoint, `{table}/{record_id}/{field_name}/{filename}` identity, CRDT-triggered pull) is real work and **is not built** (confirmed above — nothing in `server/bin/server.dart`). Building it properly means: a new HTTP endpoint on the hub, a client-side upload/download flow in `SyncService`, conflict handling for two devices adding attachments to the same record while offline, and a retry/backoff story for a large file over a flaky Wi-Fi connection between MIKE-CU and MIKE-12R. That's a sub-project on the order of Phase 1's migration-sync work, not a field-format detail.

This doc originally recommended shipping `attachment` local-only in Phase 2 (copy a picked file into `C:\Databases\essentials_app\files\{table_name}\{record_id}\{field_name}\{filename}`, no sync, a "not synced" badge in the UI). **Confirmed 2026-08-23: rejected.** A field that silently doesn't sync between MIKE-CU and MIKE-12R isn't worth shipping half-built — Mike wants attachments to work properly (local storage *and* hub sync together) or not at all for now. `attachment` is therefore **not in Phase 2's build order**. This section stays in the doc as the starting point for whenever local storage + sync gets designed and built together as its own phase — the file-path scheme, thumbnail approach (Flutter's own `Image.file` `cacheWidth`/`cacheHeight` downsampling is enough for a grid thumbnail, no dedicated thumbnailing package needed), and the sync sub-project's real scope (HTTP endpoint, upload/download flow, offline-conflict handling) are all still accurate groundwork for that future design.

### `barcode` — open question before design, not during implementation

Architecture doc: "Camera scan (Android) / text (Windows)." No package is chosen yet, and this needs the same treatment Phase 1 gave the `sqlparser`/CRDT-column risk — **a short verification spike before committing**, not an assumption baked into this design doc. Specifically: confirm a barcode-scanning package that (a) works on Android via a Flutter plugin without requiring Google Play Services assumptions that don't hold on all of Mike's hardware, and (b) degrades cleanly to a no-op/hidden scan button on Windows rather than crashing or pulling in platform code that breaks the Windows build. `mobile_scanner` is the most commonly used option as of early 2026 training-era knowledge, but package landscapes shift — worth a `flutter pub search`/pub.dev check at implementation time rather than pinning a version in this doc. Storage: plain TEXT, same as any text field — the format only changes the input method (camera on Android, keyboard on Windows), not what's stored. Low priority relative to the other formats — recommend it late in Phase 2's build order.

### `formula` — deliberately scoped below the architecture doc's full vision

The architecture doc's `formula` format (`{ expression: '...' }`) doesn't specify an evaluation engine, and the obvious candidate — `flutter_js`/QuickJS — is explicitly reserved for Phase 5's scripting engine, not a dependency yet. Pulling in a full embedded JS runtime for one field type, months before Phase 5 needs it for its actual job (event-bound automation scripts), is a lot of surface area (sandboxing, cross-platform QuickJS binary packaging on both Windows and Android) to take on early for a feature that doesn't need it.

**Recommendation: Phase 2's `formula` field supports a small, spreadsheet-style expression subset** — arithmetic (`+ - * /`), comparison, basic functions (`ROUND`, `IF`, string concatenation), and references to sibling fields on the same record by their `field_name` (`{cost} * {quantity}`). This is squarely `subscription_computed`'s old pattern (see `TableConfig.computePreview`'s doc comment, and `essentials-v2-phase1-design.md`'s note that `subscription`'s recreation is "a candidate for a `formula` field instead of the old hardcoded `table_configs.dart` layering") generalized into metadata instead of hand-written Dart. A small, dependency-light expression parser (hand-rolled recursive-descent over a tokenizer, or a minimal package like `expressions`/`math_expressions` from pub.dev — evaluate at implementation time, not pinned here) is enough; no JS engine needed. `formula` fields are `FieldConfig.readOnly = true` (already an existing concept — see `readOnly`'s doc comment, built exactly for this: `subscription`'s `yearly_cost`/`next_date`), computed at query time in `SchemaRegistry`/`GenericDao.getAll` the same way `readSource` views already work today, and previewed live via the same `computePreview` mechanism `GenericFormScreen` already calls.

When Phase 5's `flutter_js` lands, a `formula` field can optionally graduate to full JS expressions without a migration — `options.expression` is just a string either way; the only change is which evaluator reads it. Worth a one-line note in `field_definitions.options`'s eventual doc comment (`{ expression: '...', engine: 'simple' | 'js' }`) so that future doesn't require a schema change either.

### Inline `select` (option lists with no backing table)

`FieldFormatChoice.select` today only supports `mode: 'linked'` — `SchemaRegistry._lookupFor` explicitly returns `null` for anything else (`lib/db/schema_registry.dart:171`). Adding `mode: 'inline'` per the architecture doc's `options` shape (`{ mode: 'inline', options: [{key, label}, ...] }`) is genuinely new work but well-scoped: `_lookupFor` stays a `select`-only branch either way, no interaction with `_formatToFieldType`'s existing `FieldType.text` fallback for lookups. `AddFieldScreen` needs a small repeatable key/label list editor (a `ReorderableListView` of two-field rows, add/remove buttons — no new package). Storage: the option's `key` as TEXT (matching every other select's "store the key/id, resolve the label at render time" convention already established for linked selects). Grid/form rendering: a plain `DropdownButtonFormField` sourced from `options['options']` directly instead of `_dao.getLookupOptions` — no async `FutureBuilder` needed since there's no table query, which is actually simpler than the existing linked-select code path, not harder.

---

## `options` JSON — full Phase 2 shape reference

```json
// real (revised, optional)
{ "decimals": 2 }

// currency
{ "symbol": "$", "decimals": 2 }

// percentage
{ "decimals": 0 }

// rating
{ "max": 5 }

// text, with url styling (AddFieldScreen convenience, format stays "text")
{ "isLink": true }

// link_file
{}

// attachment -- NOT part of Phase 2's build order (dropped, see "Confirmed decisions"); kept for the future phase that builds local storage + sync together
{ "synced": false }

// formula
{ "expression": "{cost} * {quantity}", "engine": "simple" }

// select, inline mode (new)
{ "mode": "inline", "options": [ { "key": "low", "label": "Low" }, { "key": "med", "label": "Medium" }, { "key": "high", "label": "High" } ] }

// select, linked mode (unchanged from Phase 1)
{ "mode": "linked", "table": "priority", "displayField": "name", "valueField": "id", "on_delete": "restrict" }

// barcode
{}
```

---

## Build order

`attachment` is not in this list — dropped from Phase 2 per the confirmed decision above.

1. **`FieldFormatHandler`/`FieldFormatRegistry`** — the one prerequisite every other step depends on. Prove it on the single lowest-risk new format (`link_file`) end to end (Add Field UI → registry → grid → form → save/reload) before adding a second format, same "checkpoint before scaling out" discipline as Phase 1's build order step 5.
2. `currency`, `percentage`, `real`'s `decimals` option — all thin wrappers around the existing numeric path, batchable together.
3. `url` as a first-class `AddFieldScreen` picker entry (no new render code, see above).
4. Inline `select` — `SchemaRegistry._lookupFor`, `AddFieldScreen`'s option-list editor, grid/form dropdown sourcing.
5. `rating` — confirm TrinaGrid's custom-cell-renderer API against the pinned version before committing to a star-rendering approach in the grid; form side has no dependency on that answer.
6. `formula` — **run on Opus, per the confirmed model-tier decision above; everything else in this list runs on Sonnet.** Pick/build the expression evaluator, wire `readOnly` computation through `SchemaRegistry`/`GenericDao.getAll` and `computePreview`, verify against a real recreated `subscription`-style table (this is also the natural moment to actually recreate `subscription`, satisfying phase1-handoff's "whenever Mike chooses" note).
7. `barcode` — spike first (package choice, Android-works/Windows-degrades-cleanly confirmation), same as Phase 1 spiked the `sqlparser` risk before writing any generator code. Lowest priority; fine to slip past the rest of Phase 2 if the spike surfaces a real blocker.

---

## Open questions for implementation

- **TrinaGrid custom cell renderer API** — needed for `rating` (and useful later for `attachment` thumbnails). Confirm the exact API surface against `trina_grid: ^2.2.2` before design-locking the grid side of either format; a plain text fallback is always available if it's more friction than expected.
- **Expression evaluator package vs. hand-rolled** — `formula`'s parser is small either way; worth a 30-minute pub.dev check at implementation time for something well-maintained rather than committing to a specific package name now that may have shifted by the time this is built.
- **Attachment storage path collision on inline table-name reuse** — Phase 1's two-stage delete makes a table name reusable after stage-2 permanent delete (`SchemaEditorService._generateTableIdentifier`'s doc comment). A recreated table reusing an old name would share a `files/{table_name}/` directory with the deleted table's orphaned files unless `dropTable` also cleans up that directory. Worth a line in `dropTable`'s eventual attachment-aware update, not a Phase 2 blocker since `attachment` doesn't exist yet for `dropTable` to worry about today.
- **Barcode package choice** — deliberately left open above, not guessed at.
