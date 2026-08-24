import 'dart:convert';

/// Parses a `link_record` field's stored `TEXT` value -- always a JSON
/// array of the target table's real integer `id`s (`'[]'`, `'[42]'`,
/// `'[42,57,103]'`), regardless of whether the field is single- or
/// multi-valued (`options.multiple` is a UI-layer constraint only, never a
/// storage-format switch -- see claude/essentials-v2-phase4-design.md's
/// "Data model" section). `null`/blank/malformed JSON parses to `[]`
/// rather than throwing, same lenient spirit [parseFieldOptions] already
/// uses for the sibling `options` column.
List<int> parseLinkedIds(Object? raw) {
  if (raw == null) return const [];
  final text = raw is String ? raw : raw.toString();
  if (text.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is int)
          entry
        else if (entry is String)
          ?int.tryParse(entry),
    ];
  } catch (_) {
    return const [];
  }
}

/// The inverse of [parseLinkedIds] -- the `TEXT` value actually written to
/// a `link_record` column.
String encodeLinkedIds(List<int> ids) => jsonEncode(ids);
