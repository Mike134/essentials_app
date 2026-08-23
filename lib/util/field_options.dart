import 'dart:convert';

/// Parses a `field_definitions.options` JSON cell into a plain map --
/// shared by [SchemaRegistry] (select/lookup/`isLink`/`isColor`) and
/// [GenericDao] (select/linked/`on_delete` for `findBlockingReferences`/
/// `delete`'s cascade pass), so both consumers agree on the same lenient
/// parsing: `null`/empty -> empty map, a non-object JSON value -> empty
/// map, rather than either throwing on a field that simply has no options
/// set.
Map<String, Object?> parseFieldOptions(String? optionsJson) {
  if (optionsJson == null || optionsJson.trim().isEmpty) return const {};
  final decoded = jsonDecode(optionsJson);
  return decoded is Map<String, Object?> ? decoded : const {};
}
