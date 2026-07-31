import 'package:flutter/material.dart';

import '../db/migration_dao.dart';
import '../util/sql_statements.dart';

/// Paste/write already-proven SQL (per Mike's own workflow -- tested
/// against a disposable offline copy first, this screen is where the
/// proven result gets submitted, not where it gets figured out), a
/// description, a preview of exactly what will run, submit. See
/// CLAUDE.md "schema_admin -- migration authoring tool".
class SubmissionScreen extends StatefulWidget {
  const SubmissionScreen({super.key});

  @override
  State<SubmissionScreen> createState() => _SubmissionScreenState();
}

class _SubmissionScreenState extends State<SubmissionScreen> {
  final _dao = MigrationDao();
  final _descriptionController = TextEditingController();
  final _sqlController = TextEditingController();

  List<String> _statements = const [];
  List<SchemaSafetyBlocker>? _blockers;
  bool _checking = false;
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _sqlController.addListener(_onSqlChanged);
  }

  @override
  void dispose() {
    _sqlController.removeListener(_onSqlChanged);
    _descriptionController.dispose();
    _sqlController.dispose();
    super.dispose();
  }

  void _onSqlChanged() {
    setState(() {
      _statements = splitSqlStatements(_sqlController.text);
      _blockers = null; // stale until re-checked
    });
  }

  Future<void> _runSafetyCheck() async {
    setState(() => _checking = true);
    try {
      final blockers = await _dao.checkDropSafety(_sqlController.text);
      if (!mounted) return;
      setState(() => _blockers = blockers);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Safety check failed: $e')));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool get _hasDropStatements {
    final dropPattern = RegExp(r'\bDROP\s+TABLE\b|\bDROP\s+COLUMN\b', caseSensitive: false);
    return _statements.any(dropPattern.hasMatch);
  }

  bool get _canSubmit {
    if (_submitting) return false;
    if (_statements.isEmpty) return false;
    if (_descriptionController.text.trim().isEmpty) return false;
    if (_hasDropStatements) {
      // Must have run the check, and it must have come back clean.
      return _blockers != null && _blockers!.isEmpty;
    }
    return true;
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      await _dao.submit(
        sqlText: _sqlController.text,
        description: _descriptionController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Migration submitted.')),
      );
      _descriptionController.clear();
      _sqlController.clear();
      setState(() {
        _statements = const [];
        _blockers = null;
      });
    } catch (e) {
      setState(() => _submitError = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _sqlController,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'SQL (already tested offline -- one or more statements)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildPreview(context),
          if (_hasDropStatements) ...[
            const SizedBox(height: 12),
            _buildSafetyPanel(context),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: 8),
            Text('Submit failed: $_submitError', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_hasDropStatements)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton(
                    onPressed: _checking ? null : _runSafetyCheck,
                    child: _checking
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Run safety check'),
                  ),
                ),
              FilledButton(
                onPressed: _canSubmit ? _submit : null,
                child: _submitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Submit'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Will run as ${_statements.length} statement(s), automatically wrapped in one '
              'transaction with PRAGMA foreign_keys OFF/ON around it -- do not include '
              'BEGIN/COMMIT or foreign_keys pragmas yourself:',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _statements.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${i + 1}. ${_statements[i]}', style: const TextStyle(fontFamily: 'monospace')),
              ),
            if (_statements.isEmpty) const Text('(nothing to run yet)'),
          ],
        ),
      ),
    );
  }

  Widget _buildSafetyPanel(BuildContext context) {
    if (_blockers == null) {
      return Container(
        padding: const EdgeInsets.all(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Text(
          'This migration contains a DROP TABLE or DROP COLUMN -- run the safety check '
          'before this can be submitted.',
        ),
      );
    }
    if (_blockers!.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(8),
        color: Colors.green.withValues(alpha: 0.15),
        child: const Text('Safety check passed -- nothing else in the schema references what this drops.'),
      );
    }
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Blocked -- still referenced elsewhere:', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final blocker in _blockers!)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${blocker.statement}\n  blocked by: ${blocker.blockedBy.join(', ')}'),
            ),
        ],
      ),
    );
  }
}
