import 'package:flutter/material.dart';

import '../db/migration_dao.dart';

/// Per-device migration status -- deliberately not a flat pass/fail list.
/// The honest state might be "succeeded everywhere except MIKE-12R, which
/// is stuck at migration #7," and this screen needs to show exactly that:
/// one row per migration, one column per known device, three distinct
/// states per cell (succeeded / failed / not yet reported).
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key, this.focusMigrationId});

  /// If set, scrolls straight to this migration's row -- set when reached
  /// via "View status" from the history screen.
  final int? focusMigrationId;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  final _dao = MigrationDao();
  late Future<_StatusBoard> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_StatusBoard> _load() async {
    final history = await _dao.history();
    final devices = await _dao.knownDeviceIds();
    final statusByMigration = <int, List<MigrationStatusEntry>>{};
    for (final entry in history) {
      statusByMigration[entry.id] = await _dao.statusFor(entry.id);
    }
    return _StatusBoard(history: history, devices: devices, statusByMigration: statusByMigration);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_StatusBoard>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Failed to load status: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final board = snapshot.data!;
        if (board.history.isEmpty) {
          return const Center(child: Text('No migrations submitted yet.'));
        }
        if (board.devices.isEmpty) {
          return const Center(
            child: Text('No device has reported status yet -- nothing to show until essentials_app/server pick a migration up.'),
          );
        }

        return RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('Migration')),
                  for (final device in board.devices) DataColumn(label: Text(device)),
                ],
                rows: [
                  for (final entry in board.history)
                    DataRow(
                      color: entry.id == widget.focusMigrationId
                          ? WidgetStatePropertyAll(Theme.of(context).colorScheme.surfaceContainerHighest)
                          : null,
                      cells: [
                        DataCell(Text('#${entry.id} ${entry.description ?? ''}')),
                        for (final device in board.devices)
                          DataCell(_statusCell(context, board.statusByMigration[entry.id], device)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _statusCell(BuildContext context, List<MigrationStatusEntry>? statuses, String device) {
    final entry = statuses?.firstWhere((s) => s.deviceId == device, orElse: () => MigrationStatusEntry(
          deviceId: device,
          outcome: null,
          errorMessage: null,
          attemptedAt: null,
        ));

    if (entry == null || entry.notYetReported) {
      return const Text('not yet reported', style: TextStyle(color: Colors.grey));
    }
    if (entry.outcome == 'succeeded') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 16),
          const SizedBox(width: 4),
          Text(entry.attemptedAt ?? ''),
        ],
      );
    }
    // failed
    return Tooltip(
      message: entry.errorMessage ?? '(no error text captured)',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 16),
          const SizedBox(width: 4),
          const Text('failed'),
        ],
      ),
    );
  }
}

class _StatusBoard {
  _StatusBoard({required this.history, required this.devices, required this.statusByMigration});

  final List<MigrationLogEntry> history;
  final List<String> devices;
  final Map<int, List<MigrationStatusEntry>> statusByMigration;
}
