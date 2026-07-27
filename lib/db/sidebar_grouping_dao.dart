import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'database_helper.dart';
import 'sql_helpers.dart';

/// One row of `table_group` -- which named group a table belongs to, and
/// its position within that group. Membership is shared (same on every
/// device); see CLAUDE.md "Real-usage findings" for the governing rule.
class TableGroupMembership {
  const TableGroupMembership({
    required this.tableName,
    required this.groupName,
    this.groupPosition,
  });

  final String tableName;
  final String groupName;
  final int? groupPosition;
}

/// Reads/writes sidebar group membership (`table_group`, shared across
/// devices) and per-device group collapse state (`device_settings`, keyed
/// `sidebar_collapsed:<group_name>`) -- two different sync scopes for two
/// different concerns, per the project's governing shared-vs-per-device
/// rule, even though both are "sidebar state" from the UI's point of view.
class SidebarGroupingDao {
  SidebarGroupingDao({required this.deviceId});

  final String deviceId;

  static const String _collapsedKeyPrefix = 'sidebar_collapsed:';

  Future<SqliteCrdt> get _db async => DatabaseHelper.instance.crdt;

  Future<List<TableGroupMembership>> loadMembership() async {
    final db = await _db;
    final rows = await db.query('SELECT * FROM table_group WHERE is_deleted = 0');
    return [
      for (final row in rows)
        TableGroupMembership(
          tableName: row['table_name'] as String,
          groupName: row['group_name'] as String,
          groupPosition: row['group_position'] as int?,
        ),
    ];
  }

  /// Moves [tableName] into [groupName], placed after every table already
  /// in that group -- `table_group.table_name` is the primary key, so this
  /// is a plain upsert: a table already in some other group just gets its
  /// one row overwritten, matching "one group per table, single
  /// membership."
  Future<void> moveTableToGroup(String tableName, String groupName) async {
    final db = await _db;
    final existing = await db.query(
      'SELECT group_position FROM table_group WHERE group_name = ?1 AND is_deleted = 0',
      [groupName],
    );
    var maxPosition = -1;
    for (final row in existing) {
      final position = row['group_position'] as int?;
      if (position != null && position > maxPosition) maxPosition = position;
    }

    await db.upsert('table_group', {
      'table_name': tableName,
      'group_name': groupName,
      'group_position': maxPosition + 1,
    });
  }

  /// Replaces [groupName]'s member ordering wholesale -- every table in
  /// [orderedTableNames] gets `group_position` set to its index, and
  /// [groupName] itself (in case a table's moving into this group for the
  /// first time as part of the same reorder, e.g. dropping one table onto
  /// another in a different group). Whole-set replace rather than shifting
  /// individual positions, same reasoning as `TableViewSettingsDao
  /// .saveColumnSettings`: the caller (`HomeShell`) always has the full
  /// desired order on hand already (it's what's on screen), so there's no
  /// partial-update case to support, and it can't drift into stale gaps
  /// the way incrementing/decrementing neighbors' positions in place could.
  Future<void> setGroupOrder(String groupName, List<String> orderedTableNames) async {
    final db = await _db;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedTableNames.length; i++) {
        await txn.execute(
          'INSERT OR REPLACE INTO table_group (table_name, group_name, group_position) '
          'VALUES (?1, ?2, ?3)',
          [orderedTableNames[i], groupName, i],
        );
      }
    });
  }

  /// Deletes [tableName]'s `table_group` row -- used when a table is
  /// dragged back onto the synthetic "Ungrouped" bucket, which isn't a
  /// real persisted group (see `home_shell.dart`): un-grouping means "no
  /// row," not "a group literally named Ungrouped."
  Future<void> removeFromGroup(String tableName) async {
    final db = await _db;
    await db.deleteWhere('table_group', {'table_name': tableName});
  }

  Future<Set<String>> loadCollapsedGroups() async {
    final db = await _db;
    final rows = await db.query(
      "SELECT * FROM device_settings WHERE device_id = ?1 AND key LIKE ?2 AND is_deleted = 0",
      [deviceId, '$_collapsedKeyPrefix%'],
    );
    return {
      for (final row in rows)
        if (row['value'] == '1')
          (row['key'] as String).substring(_collapsedKeyPrefix.length),
    };
  }

  Future<void> setGroupCollapsed(String groupName, bool collapsed) async {
    final db = await _db;
    await db.upsert('device_settings', {
      'device_id': deviceId,
      'key': '$_collapsedKeyPrefix$groupName',
      'value': collapsed ? '1' : '0',
    });
  }

  static const String _lastActiveTableKey = 'last_active_table';

  /// Which table this device had open when the app was last closed --
  /// per-device by the same governing rule as collapsed groups above (Mike
  /// would be annoyed if opening the app on one device jumped him to
  /// whatever table he last had open on a *different* device). `HomeShell`
  /// falls back to the first table in nav order if this table has since
  /// been dropped or renamed.
  Future<String?> loadLastActiveTable() async {
    final db = await _db;
    final rows = await db.query(
      'SELECT * FROM device_settings WHERE device_id = ?1 AND key = ?2 AND is_deleted = 0',
      [deviceId, _lastActiveTableKey],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setLastActiveTable(String tableName) async {
    final db = await _db;
    await db.upsert('device_settings', {
      'device_id': deviceId,
      'key': _lastActiveTableKey,
      'value': tableName,
    });
  }
}
