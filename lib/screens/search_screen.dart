import 'dart:async';

import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/schema_metadata_dao.dart';
import '../db/schema_registry.dart';
import '../db/search_index_service.dart';
import 'generic_form_screen.dart';

/// Essentials v2 Phase 6 (Global Search) -- live search-as-you-type across
/// every user table's plain stored-text fields (see `SearchIndexService`'s
/// own doc comment for the confirmed scope). Reached via a search icon in
/// `HomeShell`'s nav rail/drawer, same placement pattern
/// `SettingsScreen`/`ManageTablesScreen` already use.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _service = SearchIndexService();
  final _metadataDao = SchemaMetadataDao();

  Timer? _debounce;
  Future<List<SearchResult>>? _resultsFuture;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// ~200ms debounce -- same convention column autocomplete already
  /// established for this app's own search-as-you-type voice
  /// (`lib/util/column_autocomplete.dart`).
  void _onChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() {
        _resultsFuture = _service.search(value);
      });
    });
  }

  /// Groups [results] by table, resolving each table's `display_name` the
  /// same lightweight way (`SchemaMetadataDao.loadActiveTables`, not a full
  /// `SchemaRegistry.buildConfig`) Phase 4's reverse-relation panel already
  /// uses to turn a physical table name into a label -- reused rather than
  /// duplicated. A table dropped/renamed since the index was last built
  /// (a real if narrow gap) falls back to its own bare physical name rather
  /// than disappearing or crashing.
  Future<List<_ResultGroup>> _groupResults(List<SearchResult> results) async {
    if (results.isEmpty) return const [];
    final tables = await _metadataDao.loadActiveTables();
    final displayNames = {for (final t in tables) t.tableName: t.displayName};

    final byTable = <String, List<SearchResult>>{};
    for (final result in results) {
      byTable.putIfAbsent(result.tableName, () => []).add(result);
    }
    return [
      for (final entry in byTable.entries)
        _ResultGroup(
          tableName: entry.key,
          displayName: displayNames[entry.key] ?? entry.key,
          results: entry.value,
        ),
    ];
  }

  Future<void> _openResult(SearchResult result) async {
    try {
      final config = await SchemaRegistry().buildConfig(result.tableName);
      final row = await GenericDao(config).getById(result.recordId);
      if (!mounted) return;
      if (row == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That record no longer exists.')),
        );
        return;
      }
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => GenericFormScreen(config: config, existing: row)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't open record: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search...',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _query.trim().isEmpty
          ? const Center(child: Text('Type to search across every table.'))
          : FutureBuilder<List<SearchResult>>(
              future: _resultsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final results = snapshot.data ?? const [];
                if (results.isEmpty) {
                  return const Center(child: Text('No matches.'));
                }
                return FutureBuilder<List<_ResultGroup>>(
                  future: _groupResults(results),
                  builder: (context, groupSnapshot) {
                    final groups = groupSnapshot.data;
                    if (groups == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return ListView(
                      children: [
                        for (final group in groups) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Text(
                              '${group.displayName} (${group.results.length})',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          for (final result in group.results)
                            ListTile(
                              title: _SnippetText(result.snippet),
                              onTap: () => _openResult(result),
                            ),
                          const Divider(height: 1),
                        ],
                      ],
                    );
                  },
                );
              },
            ),
    );
  }
}

class _ResultGroup {
  const _ResultGroup({required this.tableName, required this.displayName, required this.results});

  final String tableName;
  final String displayName;
  final List<SearchResult> results;
}

/// Renders an FTS5 `snippet()` string's `**...**` match markers as bold
/// text -- the markers themselves are stripped, never shown literally.
class _SnippetText extends StatelessWidget {
  const _SnippetText(this.snippet);

  final String snippet;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.*?)\*\*');
    var lastEnd = 0;
    for (final match in pattern.allMatches(snippet)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: snippet.substring(lastEnd, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < snippet.length) {
      spans.add(TextSpan(text: snippet.substring(lastEnd)));
    }
    return Text.rich(TextSpan(children: spans, style: DefaultTextStyle.of(context).style));
  }
}
