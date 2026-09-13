// Proves SidebarGroupingDao's new group-level display-order methods
// (loadGroupOrder/setGroupDisplayOrder/removeGroupOrder) against the REAL
// essentials.db. table_group_order itself is bootstrapped once, out-of-band,
// by tool/add_table_group_order_table.dart -- this file assumes it already
// exists (same assumption every other v2 DAO test makes about
// table_definitions/field_definitions).
//
// Uniquely-tagged group names + tearDown cleanup via removeGroupOrder --
// this table has no relationship to real physical tables (it's just a
// group_name -> position map), so unlike most other test files in this
// project there's no SchemaEditorService.createTable involved, and no
// crdt_sync batch-atomicity risk from creating a table -- still run this
// file on its own regardless, as a matter of course.
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/sidebar_grouping_dao.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final runTag = DateTime.now().microsecondsSinceEpoch;
  final dao = SidebarGroupingDao(deviceId: 'sgd_test_device');

  setUpAll(() async {
    await DatabaseHelper.instance.crdt;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  String tag(String name) => '${name}_$runTag';

  test('a group with no explicit order is absent from loadGroupOrder', () async {
    final order = await dao.loadGroupOrder();
    expect(order.containsKey(tag('SGD Never Ordered')), isFalse);
  });

  test('setGroupDisplayOrder writes positions matching the given order', () async {
    final a = tag('SGD Alpha');
    final b = tag('SGD Beta');
    final c = tag('SGD Gamma');
    addTearDown(() async {
      await dao.removeGroupOrder(a);
      await dao.removeGroupOrder(b);
      await dao.removeGroupOrder(c);
    });

    await dao.setGroupDisplayOrder([b, c, a]);
    final order = await dao.loadGroupOrder();

    expect(order[b], 0);
    expect(order[c], 1);
    expect(order[a], 2);
  });

  test('setGroupDisplayOrder is a whole-set replace -- a later call overwrites earlier positions', () async {
    final a = tag('SGD Replace A');
    final b = tag('SGD Replace B');
    addTearDown(() async {
      await dao.removeGroupOrder(a);
      await dao.removeGroupOrder(b);
    });

    await dao.setGroupDisplayOrder([a, b]);
    expect((await dao.loadGroupOrder())[a], 0);
    expect((await dao.loadGroupOrder())[b], 1);

    await dao.setGroupDisplayOrder([b, a]);
    expect((await dao.loadGroupOrder())[b], 0);
    expect((await dao.loadGroupOrder())[a], 1);
  });

  test('applies uniformly to a synthetic-looking group name like "Ungrouped" -- no special-casing at this layer', () async {
    final ungrouped = tag('Ungrouped');
    addTearDown(() => dao.removeGroupOrder(ungrouped));

    await dao.setGroupDisplayOrder([ungrouped]);
    expect((await dao.loadGroupOrder())[ungrouped], 0);
  });

  test('removeGroupOrder tombstones the row -- it no longer appears in loadGroupOrder', () async {
    final name = tag('SGD Removed');
    await dao.setGroupDisplayOrder([name]);
    expect((await dao.loadGroupOrder()).containsKey(name), isTrue);

    await dao.removeGroupOrder(name);
    expect((await dao.loadGroupOrder()).containsKey(name), isFalse);
  });
}
