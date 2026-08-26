import '../db/schema_editor_service.dart';
import '../db/schema_registry.dart';
import '../models/template_field.dart';
import 'field_options.dart';

/// The result of [instantiateTemplate] -- the created table's real physical
/// name, plus the display names of any fields that were skipped (never
/// created) because their `select`/`link_record` target table no longer
/// exists.
class TemplateInstantiationResult {
  const TemplateInstantiationResult({required this.tableName, required this.skippedFields});

  final String tableName;
  final List<String> skippedFields;
}

/// Creates a new table from [displayName]/[fields] via
/// [SchemaEditorService.createTable] + a sequential [SchemaEditorService
/// .addField] per field -- the exact same pipeline `NewTableScreen._submit`
/// and `CsvImportScreen`'s new-table mode both use, per
/// claude/essentials-v2-phase7-design.md's "New-table-from-headers and the
/// starter template library share one mechanism, not two." Deliberately
/// bypasses `NewTableScreen`'s own `_PendingField` UI shape -- that shape
/// only round-trips `select`/`link_record` options faithfully; a saved
/// template can in principle capture any format (`formula`, inline
/// `select`, `lookup`/`rollup`, ...), and this function's whole job is to
/// reproduce a field's `format`/`options` verbatim, not just the subset
/// `NewTableScreen`'s inline field-add row itself supports.
///
/// A `select`/`link_record` field whose target table no longer physically
/// exists (only possible for a *saved* template -- no built-in template
/// ever uses a linked format) is skipped with a warning rather than
/// failing the whole instantiation, per the design doc's "Saving a table
/// as a template" -- "never hide the record, never crash on bad field
/// metadata," the same posture Kanban's unmatched-select-value handling
/// and CSV import's malformed-value handling already established, applied
/// here to a new case.
Future<TemplateInstantiationResult> instantiateTemplate({
  required SchemaEditorService editor,
  required SchemaRegistry registry,
  required String displayName,
  required List<TemplateField> fields,
}) async {
  final tableName = await editor.createTable(displayName: displayName);
  final skipped = <String>[];

  // Sequential, not concurrent -- addField's own position lookup reads the
  // current max position first, same reasoning NewTableScreen's own submit
  // loop already documents.
  for (final field in fields) {
    final options = parseFieldOptions(field.optionsJson);
    final referencesTable = field.format == 'select' || field.format == 'link_record';
    if (referencesTable) {
      final targetTable = options['table'] as String?;
      if (targetTable == null || !await registry.tableExists(targetTable)) {
        skipped.add(field.displayName);
        continue;
      }
    }
    await editor.addField(
      tableName: tableName,
      displayName: field.displayName,
      format: field.format,
      optionsJson: field.optionsJson,
    );
  }

  return TemplateInstantiationResult(tableName: tableName, skippedFields: skipped);
}
