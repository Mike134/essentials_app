import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/generic_dao.dart';
import '../db/schema_editor_service.dart';
import '../db/schema_metadata_dao.dart';
import '../db/schema_registry.dart';
import '../db/sync_service.dart';
import '../models/table_config.dart';
import '../util/csv_import/csv_import_coercion.dart';
import '../util/field_format_choice.dart';

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

/// Which of the two flows this screen is currently showing -- see
/// claude/essentials-v2-phase7-design.md's "CSV import extension" section.
/// [existingTable] is the original, unchanged limited-CSV-import flow
/// (claude/essentials-v2-csv-import-design.md); [newTable] is Phase 7's
/// addition, sharing every later step (row coercion/commit) with it
/// unchanged -- see [_CsvImportScreenState._createTableAndCommit].
enum _ImportMode { existingTable, newTable }

/// Formats [_ImportMode.newTable]'s header-to-field-row UI offers --
/// mirrors [NewTableScreen]'s own `_supportedInitialFieldFormats` (see
/// that file's doc comment for the full reasoning: `lookup`/`rollup` need
/// a `link_record` field on this same not-yet-existing table,
/// `inlineSelect`/`formula` need a real dedicated editor this row-based UI
/// doesn't have room for), **also excluding `select`/`linkRecord`** --
/// unlike `NewTableScreen`, a raw CSV cell's text has no natural
/// correspondence to another table's row id, and building N per-row async
/// target-table pickers for every CSV header would be real UI complexity
/// for a case the design doc's own field-row sketch never actually
/// describes. A linked field can always be added afterward via Add Field/
/// Manage Fields, same as any other table.
final List<FieldFormatChoice> _supportedCsvFieldFormats = [
  for (final choice in FieldFormatChoice.values)
    if (choice != FieldFormatChoice.lookup &&
        choice != FieldFormatChoice.rollup &&
        choice != FieldFormatChoice.inlineSelect &&
        choice != FieldFormatChoice.formula &&
        choice != FieldFormatChoice.select &&
        choice != FieldFormatChoice.linkRecord)
      choice,
];

/// One CSV header's proposed field, in [_ImportMode.newTable] -- display
/// name defaults to the header text (editable), format defaults to `text`
/// (editable), [included] controls whether this header becomes a field at
/// all (the "Don't import this column" option, expressed as a checkbox
/// here rather than a dropdown entry since there's no existing-field list
/// to pick from instead).
class _NewTableFieldMapping {
  _NewTableFieldMapping({required this.headerIndex, required String header})
    : displayNameController = TextEditingController(
        text: header.trim().isEmpty ? 'Column ${headerIndex + 1}' : header.trim(),
      );

  final int headerIndex;
  final TextEditingController displayNameController;
  bool included = true;
  FieldFormatChoice format = FieldFormatChoice.text;
}

/// CSV import, per claude/essentials-v2-csv-import-design.md (the
/// original [_ImportMode.existingTable] flow: import into an *existing*
/// table's plain, non-linked fields only, no upsert/merge, single table
/// per run) extended by claude/essentials-v2-phase7-design.md with
/// [_ImportMode.newTable] -- create a brand-new table from the CSV's own
/// headers, then immediately fall into the same row-coercion/commit flow.
/// Reached from a toolbar button next to "Export to CSV" in
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
  /// a real step in this flow, not an incidental default. Only meaningful
  /// for [_ImportMode.existingTable].
  final String? initialTableName;

  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  final _metadata = SchemaMetadataDao();
  final _registry = SchemaRegistry();
  final _editor = SchemaEditorService();
  late Future<List<TableDefinitionRow>> _tableNamesFuture;

  _ImportMode _mode = _ImportMode.existingTable;

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
  /// In [_ImportMode.newTable], populated by [_createTableAndCommit] once
  /// the fields it just created are known, rather than by the user.
  final Map<int, String> _columnMapping = {};

  final _delimiterController = TextEditingController(text: ',');
  final _qualifierController = TextEditingController(text: '"');
  final _newTableNameController = TextEditingController();
  String? _newTableIdentifierPreview;
  List<_NewTableFieldMapping> _newTableFields = [];
  bool _creatingTable = false;

  bool _importing = false;
  _ImportSummary? _summary;

  @override
  void initState() {
    super.initState();
    _selectedTable = widget.initialTableName;
    _tableNamesFuture = _metadata.loadActiveTables();
    if (_selectedTable != null) _loadTargetConfig(_selectedTable!);
    _newTableNameController.addListener(_updateNewTableIdentifierPreview);
  }

  @override
  void dispose() {
    _delimiterController.dispose();
    _qualifierController.dispose();
    _newTableNameController.dispose();
    for (final field in _newTableFields) {
      field.displayNameController.dispose();
    }
    super.dispose();
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

  void _updateNewTableIdentifierPreview() {
    final name = _newTableNameController.text.trim();
    if (name.isEmpty) {
      if (_newTableIdentifierPreview != null) setState(() => _newTableIdentifierPreview = null);
      return;
    }
    _editor.previewTableIdentifier(name).then((preview) {
      if (mounted && _newTableNameController.text.trim() == name) {
        setState(() => _newTableIdentifierPreview = preview);
      }
    });
  }

  void _disposeNewTableFields() {
    for (final field in _newTableFields) {
      field.displayNameController.dispose();
    }
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv']);
    if (picked?.path == null) return; // user cancelled

    _disposeNewTableFields();
    setState(() {
      _fileError = null;
      _csvFileName = picked!.name;
      _csvHeaders = null;
      _csvDataRows = null;
      _columnMapping.clear();
      _summary = null;
      _newTableFields = [];
    });

    try {
      final content = await File(picked!.path!).readAsString();
      // Existing-table mode keeps the original auto-detecting decode
      // unchanged. New-table mode uses the delimiter/text-qualifier the
      // user configured -- autoDetect must be false for a custom
      // fieldDelimiter to actually take effect (confirmed by reading the
      // installed csv package's own source: CsvDecoder only honors a
      // non-null fieldDelimiter, and Csv() passes null whenever
      // autoDetect is true, regardless of what fieldDelimiter was given).
      final rows = _mode == _ImportMode.newTable
          ? Csv(
              fieldDelimiter: _delimiterController.text.isEmpty ? ',' : _delimiterController.text,
              quoteCharacter: _qualifierController.text.isEmpty ? '"' : _qualifierController.text,
              autoDetect: false,
            ).decode(content)
          : Csv().decode(content);
      if (rows.isEmpty) {
        setState(() => _fileError = 'That file has no rows.');
        return;
      }
      final headers = [for (final cell in rows.first) cell?.toString() ?? ''];
      setState(() {
        _csvHeaders = headers;
        _csvDataRows = rows.skip(1).toList();
      });
      if (_mode == _ImportMode.existingTable) {
        _autoSuggestMapping(headers);
      } else {
        setState(() {
          _newTableFields = [
            for (var i = 0; i < headers.length; i++)
              _NewTableFieldMapping(headerIndex: i, header: headers[i]),
          ];
        });
      }
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

  bool get _canCreateAndImport =>
      !_creatingTable &&
      !_importing &&
      _newTableNameController.text.trim().isNotEmpty &&
      _csvDataRows != null &&
      _csvDataRows!.isNotEmpty;

  String? _newTableFieldOptionsJson(FieldFormatChoice format) {
    if (format == FieldFormatChoice.url) return jsonEncode({'isLink': true});
    if (format == FieldFormatChoice.color) return jsonEncode({'isColor': true});
    return null;
  }

  /// Runs [SchemaEditorService.createTable] then a sequential
  /// [SchemaEditorService.addField] per included header -- identical code
  /// path to [NewTableScreen._submit], per the design doc -- then reuses
  /// [_commit] completely unchanged for the row-coercion/commit half, by
  /// populating the exact same state ([_selectedTable]/
  /// [_targetConfigFuture]/[_importableFields]/[_columnMapping]) the
  /// existing-table flow would have populated by the user's own picks.
  Future<void> _createTableAndCommit() async {
    final displayName = _newTableNameController.text.trim();
    if (displayName.isEmpty || _csvHeaders == null) return;

    setState(() {
      _creatingTable = true;
      _fileError = null;
    });

    try {
      final tableName = await _editor.createTable(displayName: displayName);
      final includedFields = [for (final field in _newTableFields) if (field.included) field];
      // Sequential, not concurrent -- addField's own position lookup reads
      // the current max position first, same reasoning NewTableScreen's
      // own submit already documents for its identical loop.
      for (final field in includedFields) {
        await _editor.addField(
          tableName: tableName,
          displayName: field.displayNameController.text,
          format: field.format.value,
          optionsJson: _newTableFieldOptionsJson(field.format),
        );
      }

      // This screen isn't reached through Settings, so HomeShell has no
      // existing await-and-reload hook around it the way NewTableScreen
      // gets for free -- see SyncService.notifyLocalSchemaChange's own
      // doc comment for why this call is what makes the new table
      // actually show up in nav without a relaunch.
      SyncService.notifyLocalSchemaChange();

      // addField doesn't return the identifier it generated -- rather
      // than re-deriving it ourselves (a second source of truth that
      // could drift from SchemaEditorService's own generation logic),
      // just read the fields back in position order, which matches the
      // order they were just added in one-to-one.
      final createdFields = await _metadata.loadFields(tableName, includeDeleted: false);
      final mapping = <int, String>{};
      for (var i = 0; i < includedFields.length && i < createdFields.length; i++) {
        mapping[includedFields[i].headerIndex] = createdFields[i].fieldName;
      }

      final config = await _registry.buildConfig(tableName);
      if (!mounted) return;
      setState(() {
        _selectedTable = tableName;
        _targetConfigFuture = Future.value(config);
        _importableFields = [for (final f in config.fields) if (isCsvImportable(f)) f];
        _columnMapping
          ..clear()
          ..addAll(mapping);
        _creatingTable = false;
      });

      await _commit();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creatingTable = false;
        _fileError = 'Failed to create table: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import from CSV')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (_summary != null) ..._buildSummary(_summary!) else ...[
            _buildModeToggle(),
            const SizedBox(height: 20),
            if (_mode == _ImportMode.existingTable) ..._buildExistingTableFlow() else ..._buildNewTableFlow(),
          ],
        ],
      ),
    );
  }

  Widget _buildModeToggle() {
    return SegmentedButton<_ImportMode>(
      segments: const [
        ButtonSegment(value: _ImportMode.existingTable, label: Text('Existing table')),
        ButtonSegment(value: _ImportMode.newTable, label: Text('New table')),
      ],
      selected: {_mode},
      onSelectionChanged: (selection) {
        _disposeNewTableFields();
        setState(() {
          _mode = selection.first;
          _fileError = null;
          _csvFileName = null;
          _csvHeaders = null;
          _csvDataRows = null;
          _columnMapping.clear();
          _newTableFields = [];
          _summary = null;
        });
      },
    );
  }

  List<Widget> _buildExistingTableFlow() {
    return [
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
    ];
  }

  List<Widget> _buildNewTableFlow() {
    return [
      const Text(
        'Creates a brand-new table from this file\'s header row, then '
        'imports every data row into it. Review the proposed field names '
        'and formats before creating -- every field defaults to plain '
        'text, same as typing it into New Table by hand.',
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _delimiterController,
              decoration: const InputDecoration(labelText: 'Field delimiter', hintText: 'Default: ,'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _qualifierController,
              decoration: const InputDecoration(labelText: 'Text qualifier', hintText: 'Default: "'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _buildFilePicker(),
      if (_csvHeaders != null) ...[
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 8),
        TextField(
          controller: _newTableNameController,
          decoration: InputDecoration(
            labelText: 'Table name',
            helperText: _newTableIdentifierPreview == null
                ? null
                : 'Physical name: $_newTableIdentifierPreview',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Fields', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ..._buildNewTableFieldRows(),
      ],
      const SizedBox(height: 24),
      ElevatedButton(
        onPressed: _canCreateAndImport ? _createTableAndCommit : null,
        child: (_creatingTable || _importing)
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(
                _csvDataRows == null
                    ? 'Create Table'
                    : 'Create Table & Import ${_csvDataRows!.length} row${_csvDataRows!.length == 1 ? '' : 's'}',
              ),
      ),
    ];
  }

  List<Widget> _buildNewTableFieldRows() {
    final headers = _csvHeaders!;
    return [
      for (final field in _newTableFields)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Checkbox(
                value: field.included,
                onChanged: (value) => setState(() => field.included = value ?? true),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  headers[field.headerIndex].isEmpty
                      ? '(column ${field.headerIndex + 1})'
                      : headers[field.headerIndex],
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward, size: 16),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: field.displayNameController,
                  enabled: field.included,
                  decoration: const InputDecoration(isDense: true, labelText: 'Field name'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<FieldFormatChoice>(
                  initialValue: field.format,
                  isDense: true,
                  decoration: const InputDecoration(isDense: true, labelText: 'Format'),
                  items: [
                    for (final choice in _supportedCsvFieldFormats)
                      DropdownMenuItem(value: choice, child: Text(choice.label)),
                  ],
                  onChanged: field.included
                      ? (value) => setState(() => field.format = value ?? FieldFormatChoice.text)
                      : null,
                ),
              ),
            ],
          ),
        ),
    ];
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
