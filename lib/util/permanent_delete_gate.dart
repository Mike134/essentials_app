import 'package:crdt/crdt.dart';

import '../db/sync_service.dart';

/// Shared by [ManageTablesScreen]/[ManageFieldsScreen] to decide whether
/// "Permanently delete" should be enabled for an already-soft-deleted row.
/// See [SyncService.lastConnectedAt]'s doc comment for what this comparison
/// actually proves (and doesn't).
///
/// [modifiedHlc] is the row's own `modified` column
/// ([TableDefinitionRow.modified]/[FieldDefinitionRow.modified]) -- a plain
/// `Hlc.toString()`, parsed back into the wall-clock time it was written.
bool tombstoneLikelySynced(String modifiedHlc) {
  final connectedAt = SyncService.lastConnectedAt;
  if (connectedAt == null) return false;
  try {
    final tombstoneAt = Hlc.parse(modifiedHlc).dateTime;
    return connectedAt.isAfter(tombstoneAt);
  } on FormatException {
    return false;
  }
}

/// Explains why [tombstoneLikelySynced] returned `false`, or `null` when it
/// returned `true` (nothing to explain -- the button is just enabled).
String? permanentDeleteDisabledReason(String modifiedHlc) {
  if (tombstoneLikelySynced(modifiedHlc)) return null;
  return SyncService.lastConnectedAt == null
      ? 'Waiting to confirm this device has connected to the server since '
            'this was deleted.'
      : "Not yet confirmed synced to the server -- this device's last "
            "connect happened before this was deleted. Try again after "
            "the next successful sync (every ${periodicReconnectInterval.inMinutes} "
            "minutes at most).";
}
