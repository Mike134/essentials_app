import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/schema_metadata_dao.dart';
import '../db/schema_registry.dart';
import '../models/table_config.dart';
import '../util/csv_import/csv_import_coercion.dart';

/// One outcome of coercing an entire CSV data row against the target
/// table's mapped fields -- see [coerceCsvCell] for the per-cell rules this
/// composes. Either every mapped cell produced a value to write
/// ([skipReason] `null`, [values] ready for [GenericDao.insert]) or a
/// `required` field came up empty/unparseable and the whole row is skipped
/// (per claude/essentials-v2-csv-import-design.md's "Malformed values" --
/// an all-or-nothing transaction was deliberately rejected in favor of
/// "skip and report", so one bad row never blocks the rest of the file).
class _RowCoercion {
  const _RowCoercion.store(this.values, this.warnings) : skipReason = null;
  const _RowCoercion.skip(this.skipReason) : values = const {}, warnings = const [];

  final Map<String, Object?> values;
  final List<String> warnings;
  final String? skipReason;

  bool get isSkipped => skipReason != null;
}

_RowCoercion _coerceRow(
  List<FieldConfig> fieldsByColumn,
  Map<int, String> columnMapping,
  List<dynamic> csvRow,
) {
  final values = <String, Object?>{};
  final warnings = <String>[];
  for (final entry in columnMapping.entries) {
    final field = fieldsByColumn.firstWhere((f) => f.column == entry.value);
    final rawText = entry.key < csvRow.length ? (csvRow[entry.key]?.toString() ?? '') : '';
    final coercion = coerceCsvCell(field, rawText);
    switch (coercion) {
      case CsvCellStore(:final value, :final warning):
        values[field.column] = value;
        if (warning != null) warnings.add('${field.label}: $warning');
      case CsvCellRequiredMissing(:final field):
        return _RowCoercion.skip('"${field.label}" is required but missing or unreadable');
    }
  }
  return _RowCoercion.store(values, warnings);
}

class _SkippedRow {
  const _SkippedRow(this.rowNumber, this.reason);
  final int rowNumber;
  final String reason;
}

class _ImportSummary {
  const _ImportSummary({
    required this.importedCount,
    required this.skipped,
    required this.warningCount,
  });
  final int importedCount;
  final List<_SkippedRow> skipped;
  final int warningCount;
}

/// Limited CSV import, per claude/essentials-v2-csv-import-design.md --
/// import into an *existing* table's plain, non-linked fields only. No
/// new-table-from-CSV, no upsert/merge (always append), single table per
/// run. Reached from a toolbar button next to "Export to CSV" in
/// [GenericListScreen].
///
/// A single flat, progressively-revealed `ListView` (same shape as
/// [NewTableScreen]/[AddFieldScreen] -- not a real `Stepper` widget) rather
/// than separate screens per step, since every step after the first
/// depends on state from the one before it and there's no reason to lose
/// that context by navigating away.
class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key, this.initialTableName});

  /// Pre-selects a table (e.g. the one the user was already viewing when
  /// they tapped "Import from CSV") -- editable afterward, unlike
  /// [AddFieldScreen.initialTableName], since picking the target table is
  /// a real step in this flow, not an incidental default.
  final String? initialTableName;

  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  final _metadata = SchemaMetadataDao();
  final _registry = SchemaRegistry();
  late Future<List<TableDefinitionRow>> _tableNamesFuture;

  String? _selectedTable;
  Future<TableConfig>? _targetConfigFuture;
  List<FieldConfig> _importableFields = const [];

  String? _csvFileName;
  List<String>? _csvHeaders;
  List<List<dynamic>>? _csvDataRows;
  String? _fileError;

  /// CSV column index -> target field's [FieldConfig.column]. Absent from
  /// the map (not merely `null`-valued) means "don't import this column" --
  /// matches the design doc's explicit "Don't import this column" option.
  final Map<int, String> _columnMapping = {};

  bool _importing = false;
  _ImportSummary? _summary;

  @override
  void initState() {
    super.initState();
    _selectedTable = widget.initialTableName;
    _tableNamesFuture = _metadata.loadActiveTables();
    if (_selectedTable != null) _loadTargetConfig(_selectedTable!);
  }

  void _loadTargetConfig(String tableName) {
    final future = _registry.buildConfig(tableName);
    setState(() => _targetConfigFuture = future);
    future.then((config) {
      if (!mounted || _selectedTable != tableName) return;
      setState(() {
        _importableFields = [for (final f in config.fields) if (isCsvImportable(f)) f];
      });
    });
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv']);
    if (picked?.path == null) return; // user cancelled

    setState(() {
      _fileError = null;
      _csvFileName = picked!.name;
      _csvHeaders = null;
      _csvDataRows = null;
      _columnMapping.clear();
      _summary = null;
    });

    try {
      final content = await File(picked!.path!).readAsString();
      final rows = Csv().decode(content);
      if (rows.isEmpty) {
        setState(() => _fileError = 'That file has no rows.');
        return;
      }
      final headers = [for (final cell in rows.first) cell?.toString() ?? ''];
      setState(() {
        _csvHeaders = headers;
        _csvDataRows = rows.skip(1).toList();
      });
      _autoSuggestMapping(headers);
    } catch (e) {
      setState(() => _fileError = "Couldn't read that file as CSV: $e");
    }
  }

  /// Case-insensitive match of each CSV header against an importable
  /// field's display label -- a convenience starting point, per the design
  /// doc ("not a requirement; every mapping stays user-editable").
  void _autoSuggestMapping(List<String> headers) {
    final byLabel = {for (final f in _importableFields) f.label.trim().toLowerCase(): f.column};
    setState(() {
      for (var i = 0; i < headers.length; i++) {
        final match = byLabel[headers[i].trim().toLowerCase()];
        if (match != null) _columnMapping[i] = match;
      }
    });
  }

  List<_RowCoercion> _coerceAll(Iterable<List<dynamic>> rows) => [
    for (final row in rows) _coerceRow(_importableFields, _columnMapping, row),
  ];

  Future<void> _commit() async {
    final tableName = _selectedTable;
    final dataRows = _csvDataRows;
    if (tableName == null || dataRows == null || dataRows.isEmpty) return;

    setState(() {
      _importing = true;
      _summary = null;
    });

    final dao = GenericDao(await _targetConfigFuture!);
    var imported = 0;
    var warnings = 0;
    final skipped = <_SkippedRow>[];

    // Per-row transactions (GenericDao.insert already wraps each in its
    // own crdt.transaction), not one big transaction wrapping the whole
    // file -- see the design doc's "Transaction model": a bad row skips
    // and reports, it doesn't void the rest of the import. Batched with a
    // yield between batches so a large file doesn't freeze the UI thread.
    for (var i = 0; i < dataRows.length; i++) {
      final rowNumber = i + 1; // 1-indexed CSV data row, header excluded
      final coercion = _coerceRow(_importableFields, _columnMapping, dataRows[i]);
      if (coercion.isSkipped) {
        skipped.add(_SkippedRow(rowNumber, coercion.skipReason!));
      } else {
        await dao.insert(coercion.values);
        imported++;
        warnings += coercion.warnings.length;
      }
      if (i % 50 == 49) await Future<void>.delayed(Duration.zero);
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _summary = _ImportSummary(importedCount: imported, skipped: skipped, warningCount: warnings);
    });
  }

  bool get _canCommit =>
      !_importing &&
      _selectedTable != null &&
      _csvDataRows != null &&
      _csvDataRows!.isNotEmpty &&
      _columnMapping.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import from CSV')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (_summary != null) ..._buildSummary(_summary!) else ...[
            const Text(
              'Appends rows into an existing table\'s plain fields. File '
              'should be UTF-8. Every row is inserted independently -- a '
              'row with a problem is skipped and reported, not the whole '
              'file.',
            ),
            const SizedBox(height: 20),
            _buildTablePicker(),
            if (_selectedTable != null) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 8),
              _buildFilePicker(),
            ],
            if (_csvHeaders != null && _importableFields.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 8),
              Text('Map columns', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ..._buildMappingRows(),
            ],
            if (_csvHeaders != null && _importableFields.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('This table has no importable fields (only linked/calculated ones).'),
              ),
            if (_columnMapping.isNotEmpty && _csvDataRows != null) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 8),
              Text('Preview (first 5 rows)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _buildPreview(),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _canCommit ? _commit : null,
              child: _importing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(
                      _csvDataRows == null
                          ? 'Import'
                          : 'Import ${_csvDataRows!.length} row${_csvDataRows!.length == 1 ? '' : 's'}',
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTablePicker() {
    return FutureBuilder<List<TableDefinitionRow>>(
      future: _tableNamesFuture,
      builder: (context, snapshot) {
        final tables = snapshot.data ?? const [];
        return DropdownButtonFormField<String>(
          initialValue: _selectedTable,
          decoration: const InputDecoration(labelText: 'Target table'),
          items: [
            for (final t in tables) DropdownMenuItem(value: t.tableName, child: Text(t.displayName)),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _selectedTable = value;
              _importableFields = const [];
              _csvHeaders = null;
              _csvDataRows = null;
              _columnMapping.clear();
              _summary = null;
            });
            _loadTargetConfig(value);
          },
        );
      },
    );
  }

  Widget _buildFilePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(_csvFileName == null ? 'Pick CSV file...' : 'Change file'),
            ),
            if (_csvFileName != null) ...[
              const SizedBox(width: 12),
              Expanded(child: Text(_csvFileName!, overflow: TextOverflow.ellipsis)),
            ],
          ],
        ),
        if (_fileError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_fileError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (_csvDataRows != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${_csvDataRows!.length} data row${_csvDataRows!.length == 1 ? '' : 's'} found.'),
          ),
      ],
    );
  }

  List<Widget> _buildMappingRows() {
    final headers = _csvHeaders!;
    return [
      for (var i = 0; i < headers.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(headers[i].isEmpty ? '(column ${i + 1})' : headers[i], overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward, size: 16),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String?>(
                  initialValue: _columnMapping[i],
                  isDense: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text("Don't import this column")),
                    for (final field in _importableFields)
                      DropdownMenuItem<String?>(value: field.column, child: Text(field.label)),
                  ],
                  onChanged: (value) => setState(() {
                    if (value == null) {
                      _columnMapping.remove(i);
                    } else {
                      _columnMapping[i] = value;
                    }
                  }),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _buildPreview() {
    final previewRows = _coerceAll(_csvDataRows!.take(5));
    final mappedFields = [
      for (final field in _importableFields)
        if (_columnMapping.containsValue(field.column)) field,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [for (final field in mappedFields) DataColumn(label: Text(field.label))],
        rows: [
          for (final row in previewRows)
            DataRow(
              cells: [
                for (final field in mappedFields)
                  DataCell(
                    row.isSkipped
                        ? Text(
                            'Row skipped: ${row.skipReason}',
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          )
                        : Text('${row.values[field.column] ?? ''}'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  List<Widget> _buildSummary(_ImportSummary summary) {
    return [
      Text('Import complete', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Text('${summary.importedCount} row${summary.importedCount == 1 ? '' : 's'} imported.'),
      Text('${summary.skipped.length} row${summary.skipped.length == 1 ? '' : 's'} skipped.'),
      if (summary.warningCount > 0)
        Text(
          '${summary.warningCount} value${summary.warningCount == 1 ? '' : 's'} '
          "didn't match their field's format and were stored as raw text.",
        ),
      if (summary.skipped.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Skipped rows', style: Theme.of(context).textTheme.titleMedium),
        for (final s in summary.skipped)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('Row ${s.rowNumber}: ${s.reason}'),
          ),
      ],
      const SizedBox(height: 24),
      ElevatedButton(
        onPressed: () => Navigator.pop(context, summary.importedCount > 0),
        child: const Text('Done'),
      ),
    ];
  }
}
