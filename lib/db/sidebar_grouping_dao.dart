import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

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

  Future<Database> get _db async => DatabaseHelper.instance.database;

  Future<List<TableGroupMembership>> loadMembership() async {
    final db = await _db;
    final rows = await db.query('table_group');
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
      'table_group',
      columns: ['group_position'],
      where: 'group_name = ?',
      whereArgs: [groupName],
    );
    var maxPosition = -1;
    for (final row in existing) {
      final position = row['group_position'] as int?;
      if (position != null && position > maxPosition) maxPosition = position;
    }

    await db.insert('table_group', {
      'table_name': tableName,
      'group_name': groupName,
      'group_position': maxPosition + 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Deletes [tableName]'s `table_group` row -- used when a table is
  /// dragged back onto the synthetic "Ungrouped" bucket, which isn't a
  /// real persisted group (see `home_shell.dart`): un-grouping means "no
  /// row," not "a group literally named Ungrouped."
  Future<void> removeFromGroup(String tableName) async {
    final db = await _db;
    await db.delete('table_group', where: 'table_name = ?', whereArgs: [tableName]);
  }

  Future<Set<String>> loadCollapsedGroups() async {
    final db = await _db;
    final rows = await db.query(
      'device_settings',
      where: 'device_id = ? AND key LIKE ?',
      whereArgs: [deviceId, '$_collapsedKeyPrefix%'],
    );
    return {
      for (final row in rows)
        if (row['value'] == '1')
          (row['key'] as String).substring(_collapsedKeyPrefix.length),
    };
  }

  Future<void> setGroupCollapsed(String groupName, bool collapsed) async {
    final db = await _db;
    await db.insert('device_settings', {
      'device_id': deviceId,
      'key': '$_collapsedKeyPrefix$groupName',
      'value': collapsed ? '1' : '0',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
