> **Synced copy.** This file mirrors the claude.ai Project doc of the same name (Project: "Essentials"). The claude.ai Project is where I keep it updated across chat sessions; this repo copy is what Claude Code and any local tooling should read and trust for execution. Keep both in sync going forward: when either copy changes, update the other in the same session.

---

# Essentials v2 — Limited CSV Import (side task, before Phase 4)

**Session date:** 2026-08-23
**Status:** Design confirmed 2026-08-23 — grounded in a read of the live post-Phase-2 codebase (`GenericDao`, `FieldFormatHandler`/registry, `GenericFormScreen`'s own coercion rules, `pubspec.yaml`).
**Companion docs:** `claude/essentials-v2-architecture.md` ("Roadmap sequencing"), `claude/essentials-v2-phase2-design.md`

---

## Confirmed decisions (2026-08-23, before handoff to Claude Code)

- **CSV parsing library: use the `csv` pub.dev package, confirmed** — not hand-rolled. Beyond the correctness argument below, it also pays forward: the more complex "create a new table from CSV headers" work (explicitly deferred out of this task, see "Scope") will need the same reliable parsing, so getting it right once here means that later task starts from proven parsing instead of re-litigating it.
- **Model tier: Sonnet throughout.** Nothing in this task resembles the formula evaluator's shape (novel parsing/evaluation semantics) — it's well-specified coercion rules (the table below) plus a multi-step UI screen following the existing `NewTableScreen`/`AddFieldScreen` pattern, the same bucket Sonnet already handled for six of Phase 2's seven steps.

---

## Summary

Not a phase — a side task, scoped exactly as confirmed before this design started: import into an **existing** table's **plain, non-linked** fields only. No auto-creating a table from CSV headers (real format-detection work, deliberately deferred). No importing into a linked/child-table field (needs Phase 4's link-column mechanics understood first — this doc explicitly excludes `select` fields in linked mode from the mapping targets, see "Scope" below). CSV *export* already exists and needs no work here — confirmed in the prior session by reading `GenericListScreen._exportCsv`.

The actual new work is small in field-format-catalog terms (no new formats, no schema changes) but real in UI/plumbing terms: a file picker → column-mapping → preview → commit flow, a genuinely new CSV *parsing* dependency (the app has never needed one before — export hand-rolls its own escaping, which is a fundamentally easier problem than parsing arbitrary input), and a per-format text-to-stored-value coercion table that deliberately mirrors what `GenericFormScreen`/each `FieldFormatHandler` already does on save, so an imported row looks identical to one typed in by hand.

---

## What the code already does (verified by reading it)

| Capability | Where | Relevance here |
|---|---|---|
| CSV export | `GenericListScreen._exportCsv` | Format-aware (reads `formattedValueForDisplay` per grid column), already correct for every Phase 1+2 format. No work needed. |
| Single-row insert, with `id`-default handling | `GenericDao.insert` | Reused as-is, once per imported row — see "Transaction model" below for why per-row, not one big transaction. |
| Per-format text→stored-value coercion, form side | `GenericFormScreen._currentValues` (int/real via `tryParse`, boolean via `0`/`1`, date/dateTime via `isoDate`/`isoDateTime`) and each `FieldFormatHandler.valueForSave` (currency, percentage, rating) | The importer's coercion rules (below) are written to match these exactly, field by field — not a parallel set of rules that could silently drift from what typing a value by hand produces. |
| `FieldFormatHandler`/`FieldFormatRegistry` | `lib/util/field_formats/` | Phase 2's render-layer seam. Not extended by this task — the importer calls its own coercion function directly rather than routing through the handler interface, since the handler interface is about *rendering* (grid columns, form widgets), not text parsing, and CSV import needs neither. |
| `field.isInlineSelect` / `InlineOption` | `lib/models/table_config.dart` | Phase 2's inline-`select` shape — CSV import matches a cell's text against each option's `label` (case-insensitive) to resolve the stored `key`. |
| CSV parsing package | `pubspec.yaml` | **Does not exist.** No `csv` (or equivalent) dependency. Confirmed by reading the full `dependencies:` block. |

---

## Scope (confirmed before this design started, restated precisely)

- **Target:** an existing table only, selected from `table_definitions`. No new-table-from-CSV.
- **Importable fields:** every plain field format — `text`, `integer`, `real`, `boolean`, `date`, `dateTime`, `currency`, `percentage`, `rating`, `url` (a styled `text`), `link_file`, `barcode`, and inline-mode `select`.
- **Excluded from the column-mapping targets entirely, field by field (not table by table):**
  - **Linked-mode `select`** — resolving a CSV cell's text to another table's row `id` is exactly the "child-table link" complexity this task was explicitly scoped away from. A table with a mix of plain fields and one linked field can still be imported into — the plain fields get mapped normally, the linked field simply never appears as a mapping target, same as an unmapped optional field today (stays blank / whatever `default_value` says).
  - **`formula`** — read-only, computed at query time (`FormulaService.applyTo`), never a real column write target. Never offered as a mapping target, same reasoning `GenericFormScreen._currentValues` already uses to skip `readOnly` fields on save.
  - **`id`** — never a mapping target, even if the CSV happens to have an `id` column (e.g., a file re-exported from this same app). Database-controlled everywhere else in the app; import doesn't get an exception.
- **Row semantics: always append, never upsert/merge/dedupe.** No attempt to match an imported row against an existing one by any column. Simplest correct behavior for "get real data in"; revisit only if a real need for re-importing/updating surfaces.
- **Single table per import run.** No multi-sheet/multi-table CSV handling.

---

## New dependency: a real CSV parser — confirmed, `csv` from pub.dev

`_exportCsv`'s hand-rolled escaping is safe because the app fully controls what it writes. Import has the opposite problem — arbitrary input, quite possibly from Excel or Google Sheets, with quoted fields containing commas, embedded newlines, and escaped quotes (`"He said ""hi"""`). Hand-rolling a parser for that is a real correctness risk for something with no existing test coverage or prior art in this codebase, unlike export.

**Confirmed 2026-08-23: add the `csv` package from pub.dev** (a small, widely-used, dependency-light RFC4180-ish CSV parser/writer) rather than hand-rolling. Verify current pub.dev status/version at implementation time rather than pinning one here, same discipline Phase 2's design doc used for its own new-package choices (`mobile_scanner`). Worth the investment beyond just this task: the "create a new table from CSV headers" work this doc explicitly defers (see "Scope") will need reliable parsing too, and gets to build on `csv` already being proven in this codebase rather than re-litigating the parser question later.

**Known limitation, accepted, not solved now:** encoding is assumed UTF-8. A CSV saved by an older Excel version in Windows-1252 could show mangled special characters (curly quotes, accented letters). Worth a one-line warning in the import UI ("file should be UTF-8"), not worth building encoding auto-detection for — same "consciously defer what isn't worth the effort" posture the architecture doc already states as a first-class value, not a shortcut being snuck in here.

---

## Per-format import coercion rules

Each rule is written to produce exactly what typing the equivalent value into the form and saving would produce — so an imported row and a hand-entered row are indistinguishable afterward.

| Format | CSV cell → stored value | Notes |
|---|---|---|
| `text` (incl. `url`/`link_file`/`barcode`/`isColor` fields — all plain-TEXT-backed) | Trimmed, as-is | No coercion; matches `_currentValues`'s plain-text fallback. |
| `integer` | `int.tryParse(trimmed)` | Matches `_currentValues` exactly. Failure → see "Malformed values" below. |
| `real` | `double.tryParse(trimmed)` | Matches `_currentValues` exactly. |
| `boolean` | Case-insensitive: `1`/`true`/`yes`/`y` → `1`; `0`/`false`/`no`/`n`/empty → `0` | `GenericFormScreen` itself only ever produces `0`/`1` (a checkbox has no third state) — this is the importer's own tolerant mapping for what a real-world CSV boolean column looks like, not a pattern copied from existing code. Anything else falls to "malformed" handling. |
| `date` | Try `DateTime.tryParse` (handles ISO `YYYY-MM-DD` directly), then a short list of common fallback patterns (`MM/DD/YYYY`, `M/D/YYYY`) tried in order; store via `isoDate` on success | A raw string that doesn't parse as any of these is not silently accepted as "close enough" — see "Malformed values." |
| `dateTime` | Same as `date`, extended with common `HH:mm[:ss]` suffix patterns; store via `isoDateTime` | |
| `currency` | Strip a leading currency symbol and thousands separators (`$1,234.56` → `1234.56`), then `double.tryParse` | Matches `CurrencyFormatHandler.valueForSave`'s plain-decimal-string storage. |
| `percentage` | If the cell ends with `%`, strip it and divide by 100 (`"15%"` → `0.15`); otherwise parse the number as-is (already assumed to be the stored fraction, e.g. `"0.15"` → `0.15`) | Deliberately simple, deterministic rule — no magnitude-based guessing (a percentage field can legitimately store a fraction above 1, e.g. 150% growth = `1.5`), so only an explicit `%` suffix triggers the ÷100 conversion. Matches the asymmetry `PercentageFormatHandler`'s own doc comment already calls out between stored and displayed value. |
| `rating` | `int.tryParse(trimmed)` | Not clamped to `options.max` on import — an out-of-range value is stored as-is (Excel model: no rejection), and simply renders as a fully-filled star row in the UI afterward. |
| `select`, inline mode | Case-insensitive match of the cell's trimmed text against each `InlineOption.label`; store the matching `key` | No match found → "malformed," see below — the raw text is stored anyway (so it's visible and fixable later) but won't show as a selected option in the dropdown until corrected. |

### Malformed values — the Excel model, applied to import

Two different failure shapes, handled differently, matching how the rest of this app already treats "doesn't fit the format":

- **Doesn't parse cleanly, field is not `required`:** store the raw CSV text in the column anyway, exactly as the architecture doc's core principle already states ("a value that doesn't match its format displays as-is... graceful, not broken"). The cell shows as unstyled/unparsed text in the grid until someone fixes it — same as any other non-conforming value already can, whether it arrived via import, a format change, or direct SQL. Logged in the import summary as a per-cell warning (row number, field, raw text) so it's visible, not just silently degraded.
- **Field is `required` and the cell is empty or its value maps to `null`:** the underlying column is `NOT NULL` (`SchemaEditorService.addField`'s own DDL for a required field), so an insert with that column omitted or null would throw a real `DatabaseException`, not degrade gracefully — there is no "store the raw text" option when there's no text to store. That row is skipped entirely (not partially inserted), reported in the summary with its row number and which field was missing, and the rest of the file continues processing.

---

## Transaction model: per-row, not one big transaction

`GenericDao.insert` already wraps each row in its own `crdt.transaction` — that's how every hand-typed row is written today, one at a time, with no cross-row atomicity guarantee (there's never been a "undo my last 10 form saves" feature). CSV import reuses `GenericDao.insert` per row rather than inventing a new bulk-insert path or wrapping the whole file in one transaction:

- **Consistent with existing behavior**, not a new risk category — a row that fails doesn't roll back rows that already succeeded, same as it would if you were hand-typing them one at a time and one attempt failed.
- **Matches the "skip and report" malformed-row handling above** — an all-or-nothing transaction would force the opposite choice (any one bad row voids the whole import), which is worse for a real CSV that's mostly fine with a handful of messy rows, the exact scenario this exists to handle gracefully.
- **UI implication:** process rows in small batches (e.g. 50 at a time) with a yield back to the event loop between batches, so a large file doesn't freeze the UI thread — a straightforward implementation detail, not a design question.

---

## UI flow

New screen, `CsvImportScreen`, reached from a new toolbar button in `GenericListScreen` next to the existing "Export to CSV" button — symmetric, discoverable, matches this project's established pattern of dedicated screens for structured multi-step tasks (`NewTableScreen`, `AddFieldScreen`) rather than in-place dialogs.

1. **Pick target table** — dropdown of active tables, same source `AddFieldScreen` already uses (`SchemaMetadataDao.loadActiveTables`).
2. **Pick CSV file** — `file_picker` (already a dependency), `allowedExtensions: ['csv']`, same pattern `_exportCsv` already uses for the save side.
3. **Map columns** — one row per CSV header, a dropdown of the target table's importable fields (per "Scope" above) plus an explicit "Don't import this column" option. Auto-suggest a starting mapping by case-insensitive matching CSV headers against each field's `display_name` — a convenience, not a requirement; every mapping stays user-editable. A CSV column left unmapped is simply never read. A target field left unmapped by every CSV column keeps its `default_value` (or blank) on every imported row, exactly like leaving it blank on the form.
4. **Preview** — first 5 rows, mapped and coerced, shown exactly as they'd be stored (post-coercion, not raw CSV text) so a bad mapping or date-format mismatch is visible before committing to the whole file.
5. **Commit** — runs the full file per the transaction model above, with a progress indicator for a large file.
6. **Summary** — "`N` rows imported, `M` skipped" with the skipped rows' reasons listed (required field missing), plus a count of soft warnings (values stored as raw, unparsed text) without blocking on them.

---

## Build order

1. Add the `csv` package dependency; confirm it parses a real quoted/embedded-comma/embedded-newline CSV correctly (a small throwaway test file, not a design assumption).
2. Coercion function per format (the table above) — pure logic, unit-testable in isolation before any UI exists, same "prove the mechanism first" discipline Phase 2 used for `FieldFormatHandler` on `link_file`.
3. `CsvImportScreen`: table picker → file picker → column mapping (with the auto-suggest matching) → preview.
4. Commit + per-row error handling + summary report.
5. Real-device check on both MIKE-CU and MIKE-12R with an actual messy file (a mix of clean rows, a missing-required-field row, a malformed date, an inline-select label that doesn't match any option) — confirming the skip/warn split behaves as designed, not just that the happy path works.

---

## Open questions for implementation

- **Exact `csv` package version** — pinned at implementation time, not here (package choice itself is confirmed above).
- **Date fallback pattern list** — `MM/DD/YYYY`/`M/D/YYYY` covers the common US-locale Excel export; worth confirming against Mike's actual source files (the old `Essentials.xlsx`/OneDrive exports) rather than guessing a longer list speculatively.
- **Duplicate CSV header names** — not designed here; arbitrary (first-or-last-wins) is fine for a personal tool, worth a one-line comment in the mapping code rather than a real design decision.
