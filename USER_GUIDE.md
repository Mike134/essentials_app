# Essentials — User Guide

Reference for using the app day to day. Not a design doc — see `CLAUDE.md`
and `claude/*.md` for architecture/history.

## Tables and records

- Every table has a **Grid** view by default (spreadsheet-style), plus
  whatever List/Kanban/Calendar views you've added (see "Views" below).
- **Add** (bottom-right `+`) opens a blank form. **Copy** (icon next to
  it) duplicates the currently-selected grid row into a new form,
  `id` excluded.
- Grid cells are inline-editable: click to select, click again (or
  double-click) to edit. Lookup/inline-select cells edit via a dropdown;
  linked-record cells via a picker dialog (the link icon in the cell).
- Column header menu (the hamburger icon on each column): resize, hide,
  freeze left/right, sort, filter, **Group by this column**, **Wrap
  text**, **Set column footer...** (sum/avg/min/max/count), and for
  lookup columns, **Filter by value...** (picks the real display value,
  not the underlying id).
- Right-click (Windows) or long-press-drag (Android) a table in the
  sidebar to move it into a group, or drag onto another table to reorder
  within a group. "Sort A-Z" icon on a group header sorts its members.
- Toolbar icons on a Grid view: **Import from CSV**, **Export to CSV**,
  **Restore default view** (resets column widths/order/sort/filter back
  to the table's defaults — per device, doesn't touch shared data).

## Field formats

Set when adding a field (Settings → Add a field) or changing one
(Manage fields). Every field is physically `TEXT`; format is a
presentation choice, not a storage type, so changing it later never
requires a data migration.

| Format | Notes |
|---|---|
| Text | Plain text. Column-value autocomplete offers previously-used values in the same column as you type. |
| Whole number / Decimal number | Decimal number has an optional "Decimal places" setting. |
| Yes/No | Checkbox in grid and form. |
| Date / Date & time | Calendar/time picker. |
| Choose one (dropdown lookup) | Points at another table's rows — pick the target table, the field to display, and what happens on delete (Block / Cascade / Ignore). |
| Fixed list of options | A small hardcoded list you define inline (e.g. Low/Medium/High) — no linked table. |
| Link to record(s) in another table | Links one or many rows in another table. Same Block/Cascade/Ignore choice as above. Shows as a link icon + picker in the grid, a dropdown/checkbox list in the form. |
| Show a value from a linked record | Read-only. Pick which linked-record field to pull a value from. |
| Calculate from linked records | Read-only. Sum/Average/Min/Max/Count over a linked-record field. |
| Currency / Percentage | Currency has a symbol + decimal places setting. Percentage stores as a fraction (0.15) but displays/types as a whole number (15). |
| Rating | Tappable stars, grid and form. Configurable max star count. |
| Link (URL) | Renders as a clickable link. |
| Link to a file | Form only — Browse/Open buttons; stores a plain path. |
| Color | Hex string with a swatch + picker, grid and form. |
| Barcode / QR code | Plain text field; Android form view adds a camera-scan button (no scan affordance on Windows or in the grid). |
| Calculated (formula) | Read-only. A small expression language — see below. |
| Button (runs a script) | Form only (blank in the grid). Runs its bound script on tap — see "Scripts and events." |

**Formulas** support `+ - * /`, string concatenation (`||`), comparisons
(`= != < <= > >=`), parentheses, and the functions `ROUND`, `IF`, `ABS`,
`COALESCE`, `MIN`, `MAX`. Reference other fields with `{field_name}`
(the physical field name, not the display label — check Manage Fields if
unsure). Example: `IF({qty} = 0, 0, ROUND({total} / {qty}, 2))`.

## Views

- **Grid** always exists, first in the view switcher, never something
  you create.
- **List**: groups rows by one field, two-level sort, optional extra
  line under each entry, expand/collapse groups.
- **Kanban**: one inline-select (or fixed-list) field becomes the board
  columns; drag cards between columns to change that field. A blank or
  unrecognized value gets its own column rather than being hidden.
- **Calendar**: a separate top-level nav item (not per-table) — pick
  which tables contribute via its own "Lists" checklist, Day/Week/Month.
  A table needs a date/date&time field to be eligible; pick which
  field(s) via Manage Tables' calendar-field setting.
- Manage views (icon on the view switcher bar): reorder, rename,
  soft-delete/restore a table's own List/Kanban views.

## Scripts and events

Small JavaScript snippets, run through an embedded engine, triggered by
something happening in the app.

### The JavaScript engine itself

Scripts run on QuickJS — a real, mostly-standard JavaScript engine, not a
small custom expression language. Ordinary JS builtins work as documented
on MDN: `Math`, `JSON`, `Date`, `String`/`Array`/`Object` methods, regular
expressions, `for`/`if`/functions/closures, etc. For anything that's
plain JavaScript rather than specific to this app, use MDN's reference:
<https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference>.

Everything below (`record`, `table()`, `notify()`, `navigate`) is this
app's own addition on top of that engine — it's not standard JavaScript
and won't appear in MDN or any general JS reference. It's also the
*entire* API surface this app exposes: there's no `fetch`, no file
access, no `console.log`, no way to call another script. Scripts run with
a fixed 5-second timeout (not configurable) and can't run anything
async — no `setTimeout`, no `Promise`-based work; everything below is
synchronous.

### What a script can do

```javascript
// The record this script is bound to (form/data events only -- null for
// a table-level button click with no row, or a scheduled/app_launch script).
record.get('field_name')        // read a field (physical name, not the display label)
record.set('field_name', value) // stage a change
record.save()                   // write staged changes for real
record.delete()                 // soft-delete this record

// Any table, by its display name (as shown in the sidebar) or physical name.
table('Table Name').all()              // every live row
table('Table Name').find({field: v})   // rows matching an exact-match filter
table('Table Name').create({field: v}) // insert a new row (applied after the script finishes)

notify('message')   // SnackBar (foreground) or a real OS notification (background/scheduled)

navigate.to('Table Name')     // open a table's list
navigate.toRecord(record)     // open a specific record's form
```

A script that hangs is abandoned after the 5-second timeout, not the
whole app. Writes made via `record.save()`/`table().create()` only
actually happen once the script finishes without error.

### Binding a script to something

- **Scripts** (nav sidebar): create/edit/delete scripts. Scripts and
  their event bindings are shared across devices, not per-device.
- **Manage events** (Settings): per-table bindings — pick a table, then
  an event: `record_created`, `record_updated`, `record_saved`,
  `record_deleted`, `form_opened`, `form_closed`, `field_changed` (pick
  the field), `button_clicked` (pick the button field).
- **Scheduled events** (Settings): global (not per-table) bindings —
  `app_launch` (fires every real app open), or `schedule_hourly`/
  `schedule_daily`/`schedule_weekly` (fire in the background, checked
  approximately every 15 minutes on both platforms — "daily at 8:00am"
  means the first check after 8:00am, not the exact minute).

### Background firing setup (one-time, per device)

- **Android**: tap "Allow reliable background running" on the Scheduled
  Events screen and accept the system prompt — otherwise the OS may
  delay or kill background checks.
- **Windows**: run `windows\register_background_schedule_task.ps1` once
  from an elevated PowerShell prompt. Re-run it after a fresh `flutter
  build windows` if scheduled scripts stop firing.

## Schema engine (Settings)

- **New table**: name, optional fields up front, or start from a
  built-in/saved template.
- **Add a field**: add one field to an existing table.
- **Manage fields** / **Manage tables**: rename, reorder, edit format,
  soft-delete (recoverable) and — once a soft-deleted item has had time
  to sync to every device — permanently delete (irreversible; the button
  stays disabled until that sync is confirmed).
- **Manage tables** also has **Save as Template** per table (captures its
  current field list) and the calendar-field setting.

## Import, export, backup

- **Import from CSV** (per-table toolbar icon): import rows into the
  current table, or create a brand-new table from a CSV's headers.
- **Export to CSV** (per-table toolbar icon): exports exactly what the
  grid currently shows — active filter/sort respected, display values
  (not raw ids), hidden columns skipped.
- **Backup Database** (Settings): saves a complete copy of `essentials.db`
  to a folder you pick.

## Search

**Search** (nav sidebar): full-text search across every table's plain
text fields (not linked/lookup/computed values).

## Settings

Theme preset, font family, font size (per device), font/background color
overrides (reset-to-theme available once set), grid row heights
(no-wrap/wrapped, per device).

## Sync

Changes sync automatically between devices in the background — no manual
export/import step. Scripts and their event bindings sync too, so a
script edited on one device is live on every other device.

## Known gaps / not yet built

Deliberate scope decisions and real, still-open limitations — not bugs,
just things to know before you go looking for them.

- **Button fields render blank in the grid** — form view only. Same
  precedent as barcode's scan button below; no grid interaction model was
  designed for either.
- **Barcode scan button is form-only and Android-only** — no grid
  affordance, no scan on Windows (the field is still a normal editable
  text field there).
- **Windows scheduled scripts need a one-time manual setup step**
  (`windows\register_background_schedule_task.ps1`, elevated PowerShell)
  — not registered automatically the way Android's is. Re-run it after a
  fresh `flutter build windows` if scheduled scripts stop firing.
- **Hourly/daily/weekly scripts are approximate, not exact-time**, on
  both platforms — checked roughly every 15 minutes, not scheduled for
  the precise minute.
- **No autocomplete for this app's own script API** in the script editor
  — syntax highlighting only. You're on your own for remembering
  `record`/`table()`/`notify()`/`navigate`'s exact shape (this guide is
  the reference).
- **Grid inline cell edits fire `record_updated`/`field_changed` on every
  save, even if the value didn't actually change** — the form view only
  fires `field_changed` for fields that genuinely changed; the grid's
  inline edit path doesn't currently make that distinction.
- **Windows notifications can't be individually dismissed or listed
  back** by the app (a limitation of unpackaged/non-MSIX Windows apps) —
  cosmetic only, doesn't affect whether a scheduled script ran.
- **Grid column layout (width/order/sort/filter/frozen/hidden) is
  per-device** — List/Kanban/Calendar views themselves are shared and
  sync normally, but a grid's own resize/reorder/sort/filter state is
  local to whichever device made it.
- **No named, shareable "saved views" of a grid** (e.g. a saved
  filter+sort preset that syncs across devices) — a flagged, still-unbuilt
  idea, separate from the List/Kanban/Calendar view types that do exist.
- **CSV "create a new table" import only offers plain field formats**
  (text, number, date, etc.) — a field linking to another table has to be
  added afterward via Add Field, not chosen during the import itself.
