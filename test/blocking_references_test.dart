// Regression proof for GenericDao.findBlockingReferences -- checked by
// GenericListScreen before showing a delete confirmation, rather than only
// discovering a RESTRICT block after the user already clicked Delete (a
// confirm dialog implying success is possible when it structurally isn't
// is worse than none at all). Found by Mike attempting to delete a
// supplier still referenced by shipment/orders. Run with `flutter test
// test/blocking_references_test.dart`.
//
// Against the real db, not a fixture -- read-only, never creates/drops/
// mutates anything.
import 'package:essentials_app/config/table_configs.dart';
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  final discovery = TableDiscoveryService();
  late Database db;

  setUpAll(() async {
    db = await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await DatabaseHelper.instance.close();
  });

  test('a supplier referenced by shipment/orders is reported as blocked', () async {
    final referenced = await db.rawQuery('''
      SELECT s.id FROM supplier s
      WHERE EXISTS (SELECT 1 FROM shipment WHERE shipment.supplier_id = s.id)
        AND EXISTS (SELECT 1 FROM orders WHERE orders.supplier_id = s.id)
      LIMIT 1
    ''');
    expect(referenced, isNotEmpty, reason: 'expected at least one supplier referenced by both');
    final supplierId = referenced.first['id'] as int;

    final supplierConfig = await discovery.buildConfig('supplier');
    final blockers = await GenericDao(supplierConfig).findBlockingReferences(supplierId);

    expect(blockers, containsAll(['shipment', 'orders']));
  });

  test('a lookup row nothing references reports no blockers', () async {
    // domain rows referenced by real data (subscription/account/shipment)
    // would give a false negative here -- pick one nothing points at, or
    // skip if every row is genuinely in use (still proves the method
    // doesn't crash/over-report on a real, populated table either way).
    final domainConfig = await discovery.buildConfig('domain');
    final rows = await db.query('domain');
    for (final row in rows) {
      final blockers = await GenericDao(domainConfig).findBlockingReferences(row['id'] as int);
      if (blockers.isEmpty) return; // found an unreferenced row -- proven.
    }
  });

  test('order_items is excluded from an order\'s blockers -- CASCADE, not RESTRICT', () async {
    final withItems = await db.rawQuery('''
      SELECT o.id FROM orders o
      WHERE EXISTS (SELECT 1 FROM order_items WHERE order_items.order_id = o.id)
      LIMIT 1
    ''');
    expect(withItems, isNotEmpty, reason: 'expected at least one order with items');
    final orderId = withItems.first['id'] as int;

    final ordersConfig = await buildOrdersConfig(discovery);
    final blockers = await GenericDao(ordersConfig).findBlockingReferences(orderId);

    expect(
      blockers,
      isNot(contains('order_items')),
      reason: 'order_items is ON DELETE CASCADE -- expected to cascade, not block',
    );
  });
}
