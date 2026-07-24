// Proves the last-active-table feature's storage layer
// (SidebarGroupingDao.loadLastActiveTable/setLastActiveTable) against the
// real db -- run with `flutter test test/last_active_table_test.dart`.
// Read/write only against a throwaway device_id, never touches a real
// device's own saved value.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sidebar_grouping_dao.dart';
import 'package:flutter_test/flutter_test.dart';

const String _testDeviceId = 'last-active-table-test-device';

void main() {
  late SidebarGroupingDao dao;

  setUpAll(() async {
    await DatabaseHelper.instance.database;
    dao = SidebarGroupingDao(deviceId: _testDeviceId);
  });

  tearDown(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('device_settings', where: 'device_id = ?', whereArgs: [_testDeviceId]);
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('no saved value yet returns null', () async {
    expect(await dao.loadLastActiveTable(), isNull);
  });

  test('round-trips a value, and a later write overwrites rather than duplicating', () async {
    await dao.setLastActiveTable('journal');
    expect(await dao.loadLastActiveTable(), 'journal');

    await dao.setLastActiveTable('subscription');
    expect(await dao.loadLastActiveTable(), 'subscription');
  });

  test('scoped per device_id, not shared', () async {
    await dao.setLastActiveTable('journal');
    final otherDevice = SidebarGroupingDao(deviceId: 'a-different-device');
    expect(await otherDevice.loadLastActiveTable(), isNull);
  });
}
