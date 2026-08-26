/// One field in a template's field list -- built-in
/// ([BuiltinTemplate.fields], in-memory) or user-saved
/// (`template_definitions.fields_json`, a JSON array of exactly this
/// shape). Deliberately the same shape [SchemaEditorService.addField]
/// already consumes -- instantiating a template is nothing but that
/// method called once per entry, the same loop `NewTableScreen._submit`
/// already runs for its own typed-in field list. See
/// claude/essentials-v2-phase7-design.md, "Data model".
class TemplateField {
  const TemplateField({required this.displayName, required this.format, this.optionsJson});

  final String displayName;

  /// A [FieldFormatChoice.value] string -- not the enum itself, since a
  /// template (built-in or saved) is plain data, not UI state.
  final String format;

  /// Already-serialized `field_definitions.options` JSON, or `null` --
  /// same convention [SchemaEditorService.addField] itself uses.
  final String? optionsJson;

  Map<String, Object?> toJson() => {
    'display_name': displayName,
    'format': format,
    'options_json': optionsJson,
  };

  factory TemplateField.fromJson(Map<String, Object?> json) => TemplateField(
    displayName: json['display_name'] as String,
    format: json['format'] as String,
    optionsJson: json['options_json'] as String?,
  );

  /// Lenient list parse for `template_definitions.fields_json` -- malformed
  /// entries are skipped rather than thrown on, same spirit as
  /// [InlineOption.parseList].
  static List<TemplateField> parseList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map &&
            entry['display_name'] is String &&
            entry['format'] is String)
          TemplateField.fromJson(entry.cast<String, Object?>()),
    ];
  }
}
