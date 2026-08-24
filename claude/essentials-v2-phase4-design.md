> **Source of truth: this repo file.** As of 2026-08-24, this project stopped mirroring design docs into a claude.ai Project doc -- Mike is always on the desktop app, so a claude.ai/Cowork session can read this file directly (via the device bridge) whenever it needs it, and Claude Code always reads it locally. Maintaining two full copies was pure duplicated effort with no real benefit. The claude.ai Project now keeps a single short pointer doc (`claude/project-overview.md`, the Project's own trimmed copy) instead of a full mirror of every doc -- see that doc's note for the one edge case (a browser/mobile session, no desktop app connected) this doesn't cover.

---

# Essentials v2 — Phase 4: Cross-Table Linking

**Session date:** 2026-08-24
**Status: complete, real-device verified on both MIKE-CU and MIKE-12R, 2026-08-24.** All 7 build-order steps built, then Mike's own multi-hour interactive pass across both devices (creating linked tables, single- and multi-value fields, `lookup`, the reverse-relation panel, CRDT sync between devices, CSV import) found and closed out real issues — see "Findings from interactive testing" below for the full list: the `select`/`link_record` label collision, the `condition`-table display-column crash, the `NewTableScreen` `link_record` silent-drop gap, a migration-halt incident (and its still-open root cause, flagged for a future pass), grids not refreshing live on another device's change, and the reverse-relation panel showing bare ids. Originally: Design, grounded in a read of the live codebase (`lib/db/schema_registry.dart`, `lib/models/table_config.dart`, `lib/db/generic_dao.dart`, `lib/db/schema_editor_service.dart`, `lib/db/schema_metadata_dao.dart`, `lib/screens/generic_list_screen.dart`, `lib/screens/generic_form_screen.dart`, `lib/screens/add_field_screen.dart`, `lib/screens/manage_fields_screen.dart`, `lib/util/lookup_value.dart`, `lib/util/field_format_choice.dart`, `lib/util/field_formats/field_format_handler.dart`) — same discipline Phase 1/Phase 2 followed. **Scope confirmed 2026-08-24**, see "Confirmed decisions" below.
**Companion docs:** `claude/essentials-v2-architecture.md` (the four-bullet Phase 4 roadmap entry and the `link_record`/`lookup`/`rollup` format-table rows this design fills in), `claude/essentials-v2-phase1-design.md` (schema engine this builds on), `claude/essentials-v2-phase2-design.md` (`formula`'s read-time-computed-field pattern, which `lookup`/`rollup` reuse), `claude/essentials-v2-column-autocomplete-design.md` (the `trina_grid` `editCellRenderer` hook this reuses for the grid-side picker)

---

## Confirmed decisions (2026-08-24, before handoff to Claude Code)

Two real product judgment calls this design surfaced, confirmed before implementation, same "confirmed" gate every prior phase used:

- **`link_record` cardinality is configurable per field** (`options.multiple: true | false`), not fixed. A field can be single ("which account is this expense on") or multiple ("which tasks belong to this project"), the user's choice at field-creation time — matches how Memento's own Link field works, and is what makes `rollup` genuinely useful (aggregating over a list, not a 0-or-1-item degenerate case).
- **The reverse-relation view ships in this pass, not deferred.** An existing record's form shows every other-table record whose `link_record` field points back at it (e.g. a `Person` record's form lists every `Order` linking to them) — read-only, tap to open. This is real, separate scope beyond the architecture doc's four literal bullets (`link_record`/`lookup`/`rollup`/link-picker UI), confirmed as in-scope now because it's the feature that makes cross-table linking feel complete rather than one-directional.

---

## What the code already does today (verified by reading it)

This matters more for Phase 4 than any prior phase, because Phase 4's new formats sit right next to an *existing* mechanism that looks similar but solves a different problem — getting the two confused would be a real design mistake, not a cosmetic one.

| Capability | Where | Relevance |
|---|---|---|
| `select` in **linked-table mode** — a single FK-shaped field, `options: {mode: 'linked', table, on_delete}`, stored value is the target row's real integer `id`, physically TEXT (SQLite's own TEXT-affinity conversion round-trips it silently — `lib/util/lookup_value.dart`'s `parseLookupValue` is the read-side unparse). Renders as a plain dropdown in both grid (`TrinaColumnType.select<int?>`, `GenericListScreen._buildFieldColumn`) and form (`FutureBuilder` + `DropdownButtonFormField`, `GenericFormScreen._buildField`). | `lib/db/schema_registry.dart` `_lookupFor`/`_buildField`; `lib/models/table_config.dart`'s `LookupConfig`/`FieldConfig.lookup`/`isLookup`; `lib/db/generic_dao.dart`'s `getLookupOptions`, `_linkedFieldRefs`, `findBlockingReferences`, cascade `delete` | **This is what Phase 4 builds alongside, not what it replaces.** `select`/linked stays exactly as-is — it's the right shape for a small reference table (`domain`, `priority`, `gender`) where a row genuinely has exactly one of something. `link_record` is for the general case: linking one business record to one *or many* others in any table, which is what unlocks `lookup`/`rollup`. Both formats coexist; `_linkedFieldRefs`'s FK-integrity query (see below) has to learn about both. |
| Read-only, computed-at-read-time fields | `lib/util/formula/formula_service.dart` (`FormulaService.applyTo`, called from `GenericDao.getAll`), `TableConfig.computePreview` (live preview in the form as you type, called by `GenericFormScreen`) | `lookup`/`rollup` are the same shape as `formula`: a real physical TEXT column that is deliberately never written, `FieldConfig.readOnly = true`, value filled in at read time. Reuse this pattern rather than inventing a second one. |
| The `FieldFormatHandler` registry | `lib/util/field_formats/field_format_handler.dart`'s own doc comment | **Not the right fit for `link_record`/`lookup`/`rollup`.** That interface is one `TrinaColumn` + one `TextEditingController` per field — built for Phase 2's single-value, text-backed formats. `select`/linked and inline-`select` were *already* excluded from it for the same reason (multi-async-option, non-text-controller shapes) and instead got dedicated `isLookup`/`isInlineSelect` booleans and their own branches in `GenericListScreen`/`GenericFormScreen`'s four established touchpoints (build-columns, cell-value-for, value-for-save, the editable-gating list). `link_record`/`lookup`/`rollup` follow that same "dedicated boolean + branch" precedent, not `FieldFormatHandler`. |
| `TrinaColumn.editCellRenderer` hook | Confirmed present in installed `trina_grid` 2.2.2, per `claude/essentials-v2-column-autocomplete-design.md`'s implementation notes | The grid-side picker for `link_record` (below) reuses this exact hook — already proven working for autocomplete's overlay, no new unknown to verify here. |
| `_tablesLinkingTo` | `lib/db/schema_editor_service.dart` | Already answers "which tables have a `select`/linked field pointing at table X" for `dropTable`'s safety check — the reverse-relation view's query is the same shape (which tables/fields point at X) extended to also cover `link_record` and to return matching *rows*, not just table names. |

---

## Data model

### `link_record` — the new linking format

```json
// field_definitions.options for a link_record field
{ "table": "person", "displayField": "name", "multiple": false, "on_delete": "restrict" }
```

Extends the architecture doc's original `{ table, display_field }` sketch with `multiple` (this design's own confirmed decision above) and `on_delete` (reusing `select`/linked's own three-way choice — `restrict`/`cascade`/`ignore`, same `OnDeleteChoice` enum, same meaning, same enforcement shape). `displayField` naming matches `select`/linked's own `options['displayField']` key exactly (see `SchemaRegistry._lookupFor`) rather than the architecture doc's underscore spelling, for consistency with the sibling format already in the codebase — the doc's own note there predates any actual `options` key ever being written to JSON.

**Storage: physically TEXT, always a JSON array of the target table's real integer ids** — `'[]'` (nothing linked), `'[42]'` (one), `'[42,57,103]'` (several) — regardless of `multiple`. `multiple` is a UI-layer constraint only ("does the picker let you select more than one"), never a storage-format switch: this means flipping `multiple` later on an existing field needs zero migration and no data rewrite, exactly the same "format is a presentation hint, not a storage constraint" principle every other v2 format already follows. A `multiple: false` field's picker just refuses to let the stored array grow past length 1.

This is a genuinely new storage shape for this codebase — every prior format (including `select`/linked) stores one scalar. New shared parsing lives in `lib/util/link_record.dart` (name TBD by whoever implements):

```dart
List<int> parseLinkedIds(Object? raw)      // TEXT column -> [] on null/blank/malformed JSON
String encodeLinkedIds(List<int> ids)      // -> JSON array TEXT for storage
```

Malformed/legacy JSON parses to `[]` rather than throwing — same lenient spirit `parseFieldOptions` already uses for the sibling `options` column.

### `lookup` and `rollup` — read-only, computed at read time

```json
// lookup
{ "link_field": "assigned_to", "source_field": "email" }

// rollup
{ "link_field": "tasks_field_name", "source_field": "hours", "aggregate": "sum" }
```

Matches the architecture doc's format table exactly — no changes needed to what was already drafted there. `link_field` names a `link_record` field **on the same table**; `source_field` names a field on that link's target table. Both are `FieldConfig.readOnly = true`, same enforcement `formula` already established (`SchemaRegistry._buildField`'s `isFormula` check extends to `isLookupField(format) || format == 'rollup'`, same `required: !isReadOnlyComputed && ...` guard, same "the Add Field UI hides the required/default controls for this format" treatment).

`aggregate` is one of `sum | avg | min | max | count` — `count` ignores `source_field` entirely (counts linked records, useful even when nothing numeric is being summed, e.g. "how many tasks does this project have"). `sum`/`avg`/`min`/`max` need `source_field` to resolve to something numeric on the target table; a non-numeric or missing value on a given linked row is skipped from the aggregate (not treated as zero, not a hard error) — same "graceful with non-conforming data, never a crash" posture the Field Model's core principle already commits to everywhere else.

**Display for a multi-valued `lookup`:** join every linked record's `source_field` value with `', '`, in the same order the link array stores them. No cap on count — this app's personal-scale data doesn't need one; if that assumption turns out wrong in practice it's a one-line change, not a design revisit.

**Computed at two points, mirroring `formula` exactly:**
1. **Read time** — `GenericDao.getAll()`, alongside `FormulaService.applyTo`. New `LinkedFieldService.applyTo(fields, rows)` (name TBD), same shape as `FormulaService`'s own — takes the loaded rows (which already carry the sibling `link_record` field's raw JSON-array TEXT) and fills in every `lookup`/`rollup` column's value by resolving ids against the target table.
2. **Live form preview** — `TableConfig.computePreview` already exists exactly for this ("recomputes `FieldConfig.readOnly` field values for a live preview... before the row has been saved"); `SchemaRegistry.buildConfig` already wires it up whenever `FormulaService.hasFormulaFields(fields)` is true (see that method's existing `computePreview:` line). Extend the same wiring to also fire when the table has `lookup`/`rollup` fields, and extend `LinkedFieldService` with the same "given in-progress form values, not yet saved, return the recomputed readOnly fields" shape `FormulaService.computeAllForDisplay` already has. A user adding/removing a linked record in the form sees the `lookup`/`rollup` fields update live, same UX `formula` fields already have for cost/date-driven calculations.

### New `FieldConfig` shape

```dart
class LinkRecordConfig {
  const LinkRecordConfig({
    required this.table,
    this.displayColumn = 'name',
    this.multiple = false,
    this.onDelete = 'restrict',
  });
  final String table;
  final String displayColumn;
  final bool multiple;
  final String onDelete;
}
```

New on `FieldConfig`: `final LinkRecordConfig? linkRecord;` + `bool get isLinkRecord => linkRecord != null;`, plus two more purely-boolean-flag getters mirroring `isFormula`'s existing shape: `isFieldLookup` (format `'lookup'`) and `isRollup` (format `'rollup'`) — both already covered by the existing `readOnly` field, these two just let the render layer tell "which read-only-computed kind is this" apart from `formula` at the four established touchpoints, same way `isLookup`/`isInlineSelect` already coexist as siblings today.

`SchemaRegistry._formatToFieldType` gets three more `switch` arms: `link_record` → `FieldType.text` (never actually rendered through the plain-text path — `isLinkRecord` is checked before it, same precedence `isLookup`/`isInlineSelect` already get — this is just what an *unrecognized-elsewhere* fallback would be, kept safe rather than left to synthesize a new enum value no other code expects), `lookup`/`rollup` → the same `resultType`-driven text-vs-real choice `formula` already makes (`options['resultType']`, so a `rollup` summing a currency field can still right-align and format as a number in the grid, exactly like a `formula` field does today).

---

## Referential integrity — extending, not replacing, the existing mechanism

`GenericDao._linkedFieldRefs` (backing both `findBlockingReferences`/`delete`'s cascade pass and `SchemaEditorService._tablesLinkingTo`'s drop-safety check) currently matches only `format = 'select' AND options ->> 'mode' = 'linked'`, and its row-matching is a plain scalar `WHERE column = ?1` — correct for a single FK id, wrong for `link_record`'s JSON-array storage.

**Both call sites need to also match `format = 'link_record'`, with array-aware matching** — SQLite's JSON1 extension (already relied on elsewhere in this codebase via the `->>` operator, e.g. this exact query) provides `json_each`, a table-valued function that unpacks a JSON array into rows:

```sql
-- scalar match (select/linked, unchanged)
SELECT COUNT(*) FROM other_table WHERE fk_column = ?1 AND is_deleted = 0

-- array-membership match (link_record, new)
SELECT COUNT(*) FROM other_table, json_each(other_table.link_column)
WHERE json_each.value = ?1 AND other_table.is_deleted = 0
```

`_linkedFieldRefs`'s own query (which finds every `field_definitions` row pointing at a given table) also needs its `WHERE format = 'select' AND options ->> 'mode' = 'linked'` broadened to `WHERE (format = 'select' AND options ->> 'mode' = 'linked') OR format = 'link_record'`, and the row-level `DELETE`/`COUNT` it builds per match needs to pick the scalar-vs-array-membership SQL shape based on which format that particular ref came from (carry that through `_LinkedFieldRef` as one more field, e.g. `isMultiValue`).

**Same self-reference exclusion as today, carried forward unchanged for Phase 4:** `_linkedFieldRefs` already skips `otherTable == tableName` ("no v2 table self-references today"). A table's `link_record` field pointing at itself (e.g. a `task` field linking to its own "blocked by" other `task` rows) is a real, plausible use case but genuinely new scope — not built in this pass, not blocking anything Phase 4 needs, worth its own note in "Explicitly out of scope" below rather than silently extending the existing exclusion's reach without calling it out.

**`on_delete: 'cascade'` for a multi-valued `link_record`** deletes the *referencing* row when *any one* of its linked ids is deleted (same "cascade wipes the child row" semantics `select`/linked already has, extended to "any element of the array matches" instead of "the one scalar matches") — not a partial removal of just that one id from the array. Simpler, consistent with the existing single-value cascade behavior, and avoids a whole separate "prune the array instead of deleting the row" code path this phase doesn't need.

---

## Grid rendering (`GenericListScreen`)

**`link_record` column:** reuses the `TrinaColumn.editCellRenderer` hook column autocomplete's grid editor already proved out against the installed `trina_grid` 2.2.2 (see that design doc's implementation notes) — no new API unknown here, this is a known-working mechanism being reused for a second purpose. Display (non-editing) cell shows the comma-joined display values, same join convention `lookup`'s multi-value display uses. The editing widget it renders:
- `multiple: false` — same single-select list the `select`/linked dropdown already offers, just triggered from the grid's inline editor instead of `TrinaColumnType.select`'s own picker (which structurally can't hold a JSON-array cell value) — a small popup list of the target table's rows (id + display value), tap one to set the array to `[id]` or empty to clear it.
- `multiple: true` — same popup, checkbox per row instead of tap-to-select-and-close, "Done" to commit the resulting array.

**`lookup`/`rollup` columns:** rendered exactly like `formula`'s existing read-only grid columns — plain, non-editable, right-aligned if numeric (same `_seedAggregate`-eligible treatment `formula`'s numeric result already gets, since footer sum/average on a `rollup`-of-a-`rollup` — e.g. "total hours across every task in every project" two levels up — is exactly the kind of use this app's spreadsheet-familiarity north star should make "just work" the same way any other number column's footer aggregate already does).

The four established touchpoints (`_buildFieldColumn`, `_cellValueFor`, `_onGridChanged`, the editable-gating list near where `field.isLookup`/`field.isInlineSelect` are already checked) each get one more `isLinkRecord`/`isFieldLookup`/`isRollup` branch, same shape the existing `isLookup`/`isInlineSelect` branches already have.

---

## Form rendering (`GenericFormScreen`)

**`link_record` field:** `FutureBuilder` loading `GenericDao.getLinkedRecordOptions(linkRecord)` (new method, same shape as the existing `getLookupOptions` but reading from `LinkRecordConfig.table`/`displayColumn` and returning every row, same `SELECT *`/`is_deleted = 0`/`ORDER BY displayColumn` pattern). Rendered as:
- `multiple: false` — the exact same `DropdownButtonFormField` pattern `field.isLookup`'s branch already uses, just backed by `parseLinkedIds(existingValue).firstOrNull` instead of a bare int, and writing back `encodeLinkedIds([selectedId])`/`encodeLinkedIds([])`.
- `multiple: true` — a `CheckboxListTile` per option (matches this app's existing checkbox-list idiom, e.g. `AddFieldScreen`'s own "Required"/"Autocomplete" checkboxes), backed by `parseLinkedIds(existingValue).toSet()`, writing back `encodeLinkedIds(selectedIds.toList())`.

**`lookup`/`rollup` fields:** rendered exactly like `formula`'s existing read-only form display (plain, non-editable text, live-updating via `computePreview` as described above) — no new form-rendering code needed here beyond what `readOnly` fields already get, since the extension is entirely in what feeds `computePreview`, not in how the form shows a `readOnly` field.

### New: the reverse-relation panel

Appended to the bottom of `GenericFormScreen`'s field list, **shown only when editing an existing record** (never on Add — there's no `id` yet to reverse-look-up against, same reasoning `TableConfig.openRowDetail`'s own doc comment already gives for why it's "never consulted for the Add flow"). One collapsible section per other table that has a live `link_record` field pointing at this table (query below), each listing every matching row's display value; tapping a row opens that row's own form the same way the grid's row-tap already does (reuse the existing navigation, don't build a second one).

New DAO method, `GenericDao.getReverseLinks(String tableName, int id)` (name TBD), returning e.g. `Map<TableDefinitionRow, List<Map<String, Object?>>>` (or an equivalent small record type) — grouped by the referencing table, `TableDefinitionRow` giving both the physical name (to open the row) and the display name (section header):

1. Find every `field_definitions` row with `format = 'link_record' AND options ->> 'table' = ?1` (same shape `SchemaEditorService._tablesLinkingTo` already queries, extended to also return `field_name`, not just `table_name`).
2. For each `(other_table, field_name)` pair, `SELECT * FROM other_table, json_each(other_table.field_name) WHERE json_each.value = ?1 AND other_table.is_deleted = 0` — same array-membership pattern the referential-integrity section above already establishes, reused rather than a third bespoke query shape.
3. Resolve each `other_table`'s own display column/name from its `table_definitions` row (`display_field`, `display_name`) — a lightweight direct read, not a full `SchemaRegistry.buildConfig` per table (that would pull in far more than this panel needs — every field's format/options — for a feature that only wants one label per row).

Read-only: no inline editing of the relationship from this panel. Removing/changing a link stays the other record's own `link_record` field, edited from that record's own form/grid — this panel is a viewer, not a second editor for the same data, avoiding two different code paths that could write the same array.

---

## `AddFieldScreen` / `ManageFieldsScreen`

Three new `FieldFormatChoice` entries:

```dart
linkRecord('link_record', 'Link to another table'),
lookup('lookup', 'Show a value from a linked record'),
rollup('rollup', 'Calculate from linked records'),
```

**`link_record`'s options UI** — near-verbatim copy of `select`'s existing "Linked to table" + "When the linked row is deleted" block (both screens already have this exact block, see `add_field_screen.dart`'s `_format == FieldFormatChoice.select` section and `manage_fields_screen.dart`'s mirror of it), plus one new `CheckboxListTile` ("Allow linking to more than one record") setting `multiple`. `_canSubmit`'s existing `_format == FieldFormatChoice.select && _linkedTable == null` gate gets a sibling line for `linkRecord`.

**`lookup`/`rollup`'s options UI** is genuinely new, not a copy of anything existing:
1. "Which link field" — a dropdown of *this table's own* `link_record` fields (from `_availableFields`, already loaded and already filtered-by-format-eligible for the formula editor's field-chips — this needs the same list, filtered to `format == 'link_record'` instead of "every field"; `AddFieldScreen`/`ManageFieldsScreen` currently load `Map<String, String>` field-name→display-name from `SchemaMetadataDao.loadFields`, which has everything needed — just needs the format included in what's kept, not only the two strings currently destructured out of it).
2. "Which field on the linked table" — once a link field is chosen, load *that* table's fields the same way (`SchemaMetadataDao.loadFields(linkedTable, ...)`) and offer a dropdown of them. For `rollup`, this list is naturally most useful filtered to numeric-ish formats (`integer`/`real`/`currency`/`percentage`) when `aggregate != 'count'` — a nice-to-have narrowing, not a hard validation rule (a `rollup` pointed at a `text` field with `sum` just yields "nothing summed," same graceful-non-conforming-value posture as everywhere else in the Field Model, not worth a hard block).
3. **`rollup` only** — "Aggregate" dropdown: Sum / Average / Minimum / Maximum / Count, backing `options['aggregate']`.

`_canSubmit` gains a line for each: `lookup`/`rollup` both need a chosen link field; `rollup` also needs an aggregate chosen (default to `sum` so this is really just "always satisfied unless something's badly wrong," matching how `_onDelete` already always has a sane default in the existing `select` block).

---

## Explicitly out of scope for this pass

- **Self-referencing `link_record`** (a table linking to its own other rows) — carries forward the same exclusion `_linkedFieldRefs` already has for `select`/linked (`otherTable == tableName` skipped). Real, plausible future use case; not built now, not blocking anything this phase needs.
- **Nested/multi-hop `lookup`** (a `lookup` field that reads *another* `lookup`/`rollup` field on the target table, rather than a plain stored field) — `source_field` is assumed to be a real, directly-stored value. Chaining is a reasonable future ask, adds real resolution-order complexity (what if the chain cycles?) not needed for Phase 4's core value.
- **Editing a link from the reverse-relation panel** — view-only, as described above.
- **A searchable/filtered picker for a `link_record` target table with many rows** — the picker (grid popup or form dropdown/checklist) lists every row in the target table, same "enumerate everything" approach `select`/linked's dropdown already uses today. Fine at this app's personal scale; a `getDistinctColumnValues`-style prefix-searchable picker is a reasonable future enhancement if a target table ever gets large enough to need it, not assumed necessary now.
- **CSV import into a `link_record` field** — the architecture doc's roadmap note that CSV import's "into a linked field" case was blocked on Phase 4 refers to laying the groundwork (this design), not building the import mapping itself; that stays Phase 7's job, informed by real `link_record` mechanics now existing rather than guessed at.

---

## Suggested build order

1. **Data layer** — `lib/util/link_record.dart` (`parseLinkedIds`/`encodeLinkedIds`), `LinkRecordConfig` + `FieldConfig.linkRecord`/`isLinkRecord`/`isFieldLookup`/`isRollup` on `table_config.dart`, `SchemaRegistry._buildField`/`_formatToFieldType` extensions. Unit tests: round-trip parsing (empty/one/many/malformed), `readOnly`/`required` semantics for `lookup`/`rollup`.
2. **`LinkedFieldService`** (read-time + live-preview computation for `lookup`/`rollup`, mirroring `FormulaService`'s two entry points) + `GenericDao.getAll()` wiring + `SchemaRegistry.buildConfig`'s `computePreview` wiring. Unit tests: single-value lookup, multi-value lookup join, each of the five aggregates, a linked row that's been soft-deleted (excluded), a non-numeric value hit by `sum`/`avg`/`min`/`max` (skipped, not a crash).
3. **Referential integrity** — extend `_linkedFieldRefs`/`findBlockingReferences`/cascade `delete`/`SchemaEditorService._tablesLinkingTo` for `link_record`'s array-membership matching, per the SQL shapes above. Unit tests: RESTRICT blocks a delete when linked from a multi-value array, CASCADE deletes the referencing row, IGNORE does neither, a `select`/linked reference and a `link_record` reference to the same target both still work side by side.
4. **`GenericDao.getLinkedRecordOptions`** + **`GenericDao.getReverseLinks`**. Unit tests: options list matches `getLookupOptions`'s existing shape/ordering conventions; reverse-links groups correctly across multiple referencing tables/fields, excludes soft-deleted referencing rows.
5. **`AddFieldScreen`/`ManageFieldsScreen`** — the three new `FieldFormatChoice` entries and their options UI, per the section above. Verify both screens stay in sync the way they already do for every other format (they're a near-mirror pair today — worth double-checking this build order doesn't let them drift, the same discipline the rest of this codebase already holds itself to).
6. **`GenericListScreen`** grid rendering — `link_record`'s `editCellRenderer`-based picker (single and multiple), `lookup`/`rollup`'s read-only columns, the four touchpoints' new branches.
7. **`GenericFormScreen`** — `link_record`'s dropdown/checklist, `lookup`/`rollup`'s read-only live-updating display, the new reverse-relation panel.
8. Build-verify at every step (`flutter analyze`, `flutter build windows`/`apk --debug`, unit tests), same discipline every prior phase used — then Mike's real-device pass on MIKE-CU and MIKE-12R once all seven steps are in, same "code builds and verifies, Mike tests" working agreement.

**Model tier:** steps 2 and 3 (the computed-value engine and the JSON-array-aware referential-integrity SQL) are the two steps with real correctness risk comparable to Phase 2's formula evaluator — worth the same Opus tier that got confirmed for that work. Steps 1, 4, 5, 6, 7 are routine schema-engine/UI follow-through in the same shape Sonnet already handled for every other format across Phase 1/2/CSV-import/color/autocomplete — Sonnet is the right tier there. Confirm this split with Mike before kicking off the build, same as every prior phase's tiering decision.

---

## Findings from interactive testing (2026-08-24)

**Real bug, found immediately by Mike's first Add Field attempt: the new `linkRecord` format and the pre-existing `select` (linked-lookup) format had near-identical labels in the same dropdown** — `select` was `'Linked to another table'`, `linkRecord` was `'Link to another table'`, one word apart, adjacent in the same picker. Mike picked `select` by mistake (a completely reasonable mistake, not a usage error) and then couldn't find the "Allow linking to more than one record" checkbox, since `select` never had one — it's scalar-only by design. Fixed by relabeling both, in `lib/util/field_format_choice.dart`, to be unmistakably distinct: `select` → `'Choose one (dropdown lookup)'`, `linkRecord` → `'Link to record(s) in another table'`. Labels are UI-only (the underlying `format` string is unchanged), so this was a zero-risk rename — no data migration, no test relying on the exact label text.

**Conceptual clarification requested, now baked into the field's own UI, not left as something only explained in chat:** whether `multiple` makes this a many-to-many relationship. Answer, now in both the "Allow linking to more than one record" checkbox's subtitle (`AddFieldScreen`/`ManageFieldsScreen`) and `LinkRecordConfig.multiple`'s own doc comment (`lib/models/table_config.dart`) — not just this doc, since a future field-creator needs to see it at the point of decision, not by reading a design doc:

- `multiple: false` — **one-to-many**. This field picks a single target row, but that target row can be linked from many rows on this side (e.g. many `Task`s each pointing at one `Project`).
- `multiple: true` — **many-to-many**. This field can pick several target rows, and each of those can independently be linked from many rows on this side too (e.g. many `Task`s each linking several `Person`s as assignees, any `Person` assignable to any number of `Task`s).
- **Either way, there is no join table and nothing mirrored onto the target table's own side** — the relationship is stored entirely as this field's JSON array; the reverse direction is derived on demand by `GenericDao.getReverseLinks` (surfaced via the reverse-relation panel on the target row's own form), not a second field anyone has to create or keep in sync.

**A crash, found live via Mike's own real testing, that turned out to be a *pre-existing* `select`/linked bug, not a `link_record` one:** opening the `Task` table's grid threw `no such column: name` — `SELECT * FROM condition WHERE is_deleted = 0 ORDER BY name`. Root cause: `Task`'s "Condition" field (`select`/linked, created before this session, pointing at a `condition` table whose own text field happens to be named `condition`, not `name`) had no `options.displayField` override, and `SchemaRegistry._lookupFor`/`_linkRecordFor` both default that to a literal `'name'` with nothing checking it actually exists. Fixed two ways: (1) `GenericDao._resolveDisplayColumn` — a defensive safety net in `getLookupOptions`/`getLinkedRecordOptions`, falling back to `id` (with an alias back onto the configured key, so a caller reading `option[displayColumn]` never sees a missing key) rather than crashing, covering every field that predates the next fix; (2) a real "Which field to show" picker added to *both* `select`'s and `link_record`'s options UI in `AddFieldScreen`/`ManageFieldsScreen` (`autoDisplayField`: prefers an actual `name` field if the target has one, else the target's first `text` field, else `id`), so a *newly created* field always writes an explicit, verified-to-exist column instead of silently hoping `'name'` exists. New tests in `test/generic_dao_step4_test.dart`'s "display column resilience" group cover both the fallback and the explicit-column case.

**Real gap in `NewTableScreen`, found from Mike's own question ("why does this option just go away") rather than a crash:** `link_record` had been offered in New Table's inline Format picker since it shipped, but only `select`'s branch ever populated the target-table/on-delete UI or wrote real `options` JSON — picking `link_record` there silently produced a field with no `table` key at all (never actually became a link, per `SchemaRegistry._linkRecordFor`'s `null`-if-no-table rule). Root design question Mike raised: why do *some* formats work fully in New Table and others require a trip to Add Field afterward? Answer, now the standing rule (`new_table_screen.dart`'s own `_supportedInitialFieldFormats` doc comment) — a format belongs in New Table's picker only if it can be **fully** supported there, never "listed but silently degraded":
- `select`/`link_record` point at an *already-existing other table* — nothing structurally prevents full support, this was simply an incomplete implementation. Fixed: `link_record` now gets the exact same target-table + on-delete + "which field to show" + "allow multiple" block `select` already had (and `select` itself also gained the same "which field to show" picker, closing the crash above at the source for anything created from here on).
- `lookup`/`rollup` reference a **link field on the same table being created** — for the very first field, that field doesn't exist yet. A genuine ordering constraint, not a UI gap; these stay excluded from New Table's picker, added afterward via Add Field once the table (and its link field) exist.
- `inlineSelect`/`formula` need a real dedicated editor (an option-list builder, an expression builder) that would defeat this screen's own stated minimalism; also excluded from New Table's picker for the same reason `AddFieldScreen` exists as its own screen at all.
- `url`/`color` had the *identical* silent-drop bug (their flag was never written from New Table, so they quietly became plain text) — fixed alongside `link_record` since the cost was trivial.
- Currency/percentage/rating/barcode were already fine as-is — they degrade to sensible, correct defaults with no options captured, which is genuinely correct behavior, not a gap.

**Two real, incident-grade bugs during this same real-usage pass — both from the migration-halt-on-failure design doing exactly what it's meant to (surface a failure loudly, never silently retry), but each halt happened to land in Mike's way at the worst possible moment.**

1. Mid-session, an earlier cleanup pass (retracting a poisoned test migration, catching up the queue) left one more poisoned migration behind — a stray `DROP TABLE` re-authored against a table that, by the time it ran, had already been dropped by an earlier, successful attempt at the same drop (a real, if narrow, race: `SchemaEditorService.dropTable`'s precondition only checks `table_definitions.is_deleted`, not physical existence, so calling it twice on the same table — once from an automated cleanup script, once from Mike's own concurrent "delete everything" pass in Manage Tables — authors a second DDL that's *guaranteed* to fail). That failure halted MIKE-CU's whole migration queue silently from that point on: every subsequent `Create Table`/`Add Field` on MIKE-CU (including three back-to-back attempts at a "Status" table) wrote real metadata but never got its physical DDL applied, each failing at the very first field with `No table named "..." exists`. Root-caused via direct SQL inspection, not guessed — fixed by retracting the poisoned migration through the app's own synced API (`SqliteCrdt.deleteWhere`, never raw SQL against the sync layer) and letting `MigrationService.applyPending` catch up; recovered three duplicate empty "Status" tables this had silently produced (one per failed attempt) down to the one Mike actually wanted, via the real stage-1/stage-2 drop pipeline.
2. This is the second time this exact failure shape (`dropTable` called twice on the same table) has bitten a real session — worth a real fix rather than a third recovery write-up next time it happens. **Not fixed this session** (flagged here for a future pass): `dropTable`'s precondition should check physical existence via `sqlite_master`, not just `is_deleted`, and either no-op cleanly or refuse with a clear "already gone" message instead of authoring a DDL statement that's certain to fail.

**Two real, standing gaps Mike's own multi-hour, both-devices testing pass surfaced, both now fixed, neither a `link_record`-specific bug:**

1. **Grids didn't refresh live when another device changed the same table's data.** Sync itself always worked; nothing made an already-open `GenericListScreen` reload when a row arrived from elsewhere — the exact same "sync works, the *display* side's reactivity doesn't" gap `SyncService.schemaChanges` had already closed for nav/table-list changes (CLAUDE.md "Essentials v2 Phase 1 — Step 9 follow-up"), just never extended to ordinary row data. Fixed with a new `SyncService.dataChanges` (`Stream<Set<String>>`, fed from the same `onChangesetReceived` hook, naming every table an incoming changeset touched) — `GenericListScreen` subscribes and debounced-reloads whenever its own table is in that set. Symmetric with `schemaChanges`'s own debounce reasoning: `onChangesetReceived` fires before the merge is awaited, so reloading instantly risks reading pre-merge data.
2. **The reverse-relation panel showed a bare row id for every linked child, with no way to tell them apart short of tapping each one.** Root cause: `ReverseLink.displayColumn` fell back to the referencing table's `table_definitions.display_field` — which, it turns out, **no v2 table's UI has ever set**, on any table, ever (confirmed directly: every table created through the schema engine defaults it to `null`/`id`). Fixed by having `GenericDao.getReverseLinks` fall back further, past the unset `display_field`, to the referencing table's own first field by position — and by having the panel show **both** the id and that value together (`"$id — $value"`), per Mike's explicit ask, rather than picking one or the other. New tests in `test/generic_dao_step4_test.dart` cover the fallback chain, including the narrow edge case where the link field itself is a table's only field.
