> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

---

# Essentials v2 — Column Autocomplete (side task, before Phase 4)

**Session date:** 2026-08-24
**Status:** Done — built, build-verified, and Mike-verified interactively on both MIKE-CU and MIKE-12R. One real bug found and fixed mid-verification (grid autocomplete needed a paired `FocusNode`, not just a `textEditingController` — see "Implementation notes" below). Full write-up in `CLAUDE.md`'s "Column autocomplete" section.
**Companion docs:** `claude/essentials-v2-architecture.md` (field format catalog), `claude/essentials-v2-phase2-design.md` (`FieldFormatHandler` pattern this follows)

## Implementation notes (added post-build, Claude Code)

- **`trina_grid` 2.2.2 confirmed to have exactly the hook step 1 asked to
  verify:** `TrinaColumn.editCellRenderer` (`Widget Function(Widget
  defaultEditCellWidget, TrinaCell cell, TextEditingController controller,
  FocusNode focusNode, Function(dynamic value)? handleSelected)`) —
  `text_cell.dart`'s `TextCellState.build` checks it before falling back to
  the plain `TextField`. No manual-`OverlayEntry` fallback was needed.
- **Both the grid and form editors use Flutter's built-in `Autocomplete<String>`**
  (not `RawAutocomplete` directly) — confirmed against the installed SDK
  (Dart 3.12.2 / Flutter 3.44.6) that `optionsBuilder`'s typedef is
  `FutureOr<Iterable<T>> Function(TextEditingValue)`, i.e. genuinely async,
  so `GenericDao.getDistinctColumnValues` runs for real on every call —
  no synchronous-cache workaround needed. `ColumnAutocompleteSource`
  (`lib/util/column_autocomplete.dart`) debounces (~200ms) and guards
  against a slow, superseded call clobbering a newer one, shared by both
  surfaces per the design doc's "one suggestion source" requirement.
- **Real, confirmed keyboard-navigation gap in the grid, not present on
  the form:** arrow-key/Enter highlight-and-accept (the design doc's step
  4) works on the form side but does **not** work in the grid. Read from
  `trina_grid`'s source, not guessed: the grid's text cell editor already
  has its own `FocusNode` with an `onKeyEvent` handler
  (`TextCellState._handleOnKey`) that unconditionally claims vertical
  arrows/Enter/Escape/Tab for its own cell-navigation purposes, and since
  that node is the one actually holding focus, `Autocomplete`'s own
  `Shortcuts` wrapper (an ancestor once composed in) never sees those key
  events. Mouse/touch tap-to-select is unaffected and works identically
  in both places; typing a value and pressing Enter/Tab/Escape still
  behaves exactly as it always has. Documented in code at
  `GenericListScreen._buildGridAutocompleteEditor`'s doc comment. Not
  pursued further this session (would mean patching around `trina_grid`'s
  own `FocusNode`, a materially bigger lift) — flagged here per the design
  doc's own invitation to check in if this surfaced.
- **Form-side single-line exception:** an autocomplete-eligible field's
  form widget uses `maxLines: 1`, not this screen's usual `maxLines: null`
  auto-grow — confirmed by reading the Flutter SDK's own `Autocomplete`
  default field builder, which is single-line, because a multi-line
  `EditableText` consumes vertical-arrow key events for its own caret
  movement before `Shortcuts` ever sees them, silently breaking
  keyboard highlight navigation. Reasonable given these fields are short
  recurring values (a city, a category, a name), not notes fields.
- **`FieldConfig.isAutocompleteText`** encodes eligibility precisely:
  `format == 'text' && type == FieldType.text && !isLink && !isColor &&
  options['autocomplete'] != false` — `url`/`color` both also store as
  plain `format: 'text'` with an options flag (see `FieldFormatChoice`'s
  doc comment) but already have their own dedicated widget, so they're
  excluded even though their raw `format` matches.
- **Real bug found and fixed during interactive verification:** the first
  version of the grid editor passed `Autocomplete`'s `textEditingController`
  without its required paired `focusNode` -- caught by an assert in
  `RawAutocomplete`'s constructor that's stripped from release builds, so
  it silently fell back to a disconnected internal `FocusNode` that never
  saw real focus events, and the suggestion overlay never appeared in the
  grid (form worked correctly throughout, since it wires its own real
  `FocusNode`). Fixed by passing the real `FocusNode` -- the exact one
  `editCellRenderer` already hands the callback as its 4th parameter,
  previously left unused.
- **Done:** Mike's interactive verification on both MIKE-CU (Windows exe)
  and MIKE-12R (debug APK) -- grid and form both confirmed working,
  click/tap-to-select confirmed correct in the grid.

---

## What this is

Type-ahead suggestions drawn from values already entered elsewhere in the same column, offered while typing into a cell — both in the grid (`GenericListScreen`) and the record form (`GenericFormScreen`). Same idea as Excel's cell AutoComplete or Memento's field suggestions. Confirmed with Mike 2026-08-24, before Phase 4 starts.

Not a phase — a small side task, same category as the `color` field format fix and CSV import. No new phase number.

---

## Confirmed scope (2026-08-24, narrowed same day after re-evaluation)

- **Fields:** `text` only. First pass of this doc scoped in `url`/`barcode`/`link_file` too, but on review those don't earn their keep: `url`s and `link_file` paths are usually distinct per row (autocomplete mostly returns nothing useful), and `barcode` is either camera-scanned (no typing to assist) or, on Windows, typically a unique-per-item code (again nothing to suggest). `text` is the one format where repeated values across rows — a city, a category someone free-types instead of using `select`, a recurring name — are genuinely common. `text_multiline` stays excluded (long free-form notes rarely repeat verbatim).
  Formats deliberately **not** getting this: `integer`/`real`/`currency`/`percentage` (numeric keypad entry, no natural typeahead UX), `boolean`/`select`/`rating`/`color`/`date`/`dateTime` (already have their own constrained-choice widget), `formula` (read-only), `url`/`barcode`/`link_file`/`text_multiline` (per above), `link_record`/`lookup`/`rollup` (Phase 4, not built yet).
- **Surface:** both grid inline edit and form entry, sharing one suggestion source so behavior is identical in both places.
- **Suggestion source:** live `SELECT DISTINCT` against the table for that field, filtered by what's typed so far — no new schema, no cache table, no pre-built index. Simplest thing that works; revisit only if a real table gets large enough that this is slow in practice (nothing in the app today suggests that's likely — these are personal-scale tables).

## Per-field opt-out

Even within `text`, not every field should necessarily get suggestions (e.g. a `text` field used for genuinely unique values — a serial number, a one-line description — would just show noise). Add `options.autocomplete: true | false` to `field_definitions.options`, same JSON-options pattern every other format uses (`{isLink: true}`, `{isColor: true}`, etc.).

**Default:** `true` for `text`. Surfaced as a toggle in `AddFieldScreen` and `ManageFieldsScreen`'s field editor, next to the other per-format options — same two screens the `color` fix touched. Since `text` is now the only eligible format, this toggle is the only scope control that matters; no other format shows it.

---

## Data layer

New `GenericDao` method, name TBD by whoever implements (`getDistinctColumnValues` or similar):

```
Future<List<String>> getDistinctColumnValues(
  String tableName,
  String fieldName, {
  String prefix = '',
  String? excludeValue,   // don't suggest the value already in the cell
  int limit = 20,
})
```

- `SELECT DISTINCT "<fieldName>" FROM "<tableName>" WHERE is_deleted = 0 AND "<fieldName>" IS NOT NULL AND "<fieldName>" != '' AND "<fieldName>" LIKE ?||'%' COLLATE NOCASE ORDER BY "<fieldName>" LIMIT ?`
- Prefix match, not substring/fuzzy — standard autocomplete behavior, cheapest query, matches the "distinct prior values" scope Mike confirmed. Substring/fuzzy match is a possible future enhancement, not in scope now.
- `is_deleted = 0` — respect the existing soft-delete convention (see `project-overview.md`'s CRDT bookkeeping section); don't suggest values that only exist on tombstoned rows.
- Table/field names are interpolated (SQLite doesn't parameterize identifiers) — reuse whatever existing helper the codebase already uses for this elsewhere (`GenericDao.getAll` already builds dynamic-table queries; follow its existing escaping/quoting convention rather than inventing a new one).
- Debounce calls from the UI layer (~200ms) rather than querying on every keystroke.

---

## Form-side implementation (`GenericFormScreen`)

Lowest-risk part of this task — Flutter ships a built-in `Autocomplete<String>` widget (or `RawAutocomplete` for more layout control) that does exactly this: wraps a text field, calls an async `optionsBuilder`, renders a suggestion overlay, handles selection/dismissal. Wire it in wherever `GenericFormScreen._buildField` currently builds a plain `TextFormField` for a `text` format field, gated on `field.options['autocomplete'] != false` (default true). `optionsBuilder` calls the new DAO method with the current table/field/typed-prefix.

---

## Grid-side implementation (`GenericListScreen` / TrinaGrid)

**This is the part Claude Code should verify against the actual installed `trina_grid` version before building** — the plan below is the intended approach, not confirmed against the package API:

1. Check whether `trina_grid` supports a custom cell editor / renderer plugin for `TrinaColumnType.text()` that can host a suggestion overlay while editing (some PlutoGrid-family forks expose an editor-widget-builder hook; confirm what this fork actually has).
2. If yes: use it to render the same suggestion list as the form side, positioned under the active cell, same DAO call and debounce.
3. If the grid API doesn't cleanly support that: fall back to a manually-positioned `OverlayEntry` — on cell-edit-start, compute the cell's on-screen rect (TrinaGrid exposes cell/row rendering info for this kind of thing already, per the existing row-coloring and inline-select-editing features), show a small suggestion list overlay anchored to it, filter as the user types, dismiss on selection, Escape, or tapping away.
4. Either way: same keyboard behavior expected from any autocomplete — arrow keys move selection in the suggestion list, Enter/Tab accepts the highlighted suggestion, Escape dismisses and leaves typed text as-is.

If both the plugin hook and a clean overlay approach turn out to be a bigger lift than expected, that's worth a quick check-in before spending a lot of time on it — grid-side autocomplete is the one piece of this task with real unknowns; form-side and the DAO layer are not.

---

## Explicitly out of scope for this pass

- Fuzzy/substring matching (prefix only)
- Cross-table suggestions (only the same column, same table)
- Suggestions for `link_record`/`lookup`/`rollup` (don't exist yet — Phase 4's job)
- A cached/indexed suggestion store (live `DISTINCT` query is enough at this data scale)
- Learning from typing patterns/frequency ranking beyond simple prefix match + alphabetical order

---

## Suggested build order

1. `GenericDao.getDistinctColumnValues` + a couple of unit tests (empty table, prefix match, excludes soft-deleted rows, respects `excludeValue`).
2. `options.autocomplete` toggle in `AddFieldScreen`/`ManageFieldsScreen`, `text` format only, default `true`.
3. Form-side wiring (`GenericFormScreen`) — low risk, ships value immediately even if grid-side takes longer.
4. Grid-side wiring (`GenericListScreen`) — after confirming the `trina_grid` API question above.

Model tier: routine UI/DAO work, no expression-evaluator-shaped complexity — Sonnet is the right tier for all four steps, consistent with the tiering rule the Phase 2 handoff established.
