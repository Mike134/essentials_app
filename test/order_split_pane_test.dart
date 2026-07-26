// Regression proof for CLAUDE.md "Split-Pane Layout" session, Parts A-D:
// orders/order_items resolve through the same discovery + field_metadata
// mechanism as every other table, with orders/order_items' known,
// deliberate exceptions layered on top (see table_configs.dart's
// buildOrdersConfig/buildOrderItemsConfigForOrder doc comments). Run with
// `flutter test test/order_split_pane_test.dart`.
//
// Against the real db, not a fixture -- read-only, never creates/drops/
// mutates anything. Assumes the real seed data this session's instructions
// described (5 orders, 4-5 items each) -- if that data is ever cleared,
// the "at least one order has items" tests below will fail loudly rather
// than silently pass on an empty case.
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

  test('orders/order_items id is never a FieldConfig despite pk=0 on PRAGMA table_info', () async {
    // Both tables' id uses a timestamp+random SQL default rather than
    // INTEGER PRIMARY KEY AUTOINCREMENT (the new convention for all future
    // tables, to avoid collisions between offline Windows/Android inserts
    // ahead of a Syncthing sync) -- PRAGMA table_info reports pk=0 for it,
    // so this only holds because TableDiscoveryService also matches a
    // literal `id` column by name.
    final ordersColumns = await db.rawQuery('PRAGMA table_info("orders")');
    final ordersIdRow = ordersColumns.firstWhere((r) => r['name'] == 'id');
    expect(ordersIdRow['pk'], 0, reason: 'orders.id is deliberately not a SQL PRIMARY KEY');

    final ordersConfig = await buildOrdersConfig(discovery);
    expect(
      ordersConfig.fields.any((f) => f.column == 'id'),
      isFalse,
      reason: 'id must never become a FieldConfig',
    );

    final itemsConfig = await discovery.buildConfig(orderItemsTableName);
    expect(itemsConfig.fields.any((f) => f.column == 'id'), isFalse);
  });

  test('orders.order_number is UNIQUE, and its displayColumn resolves to it rather than the bare id', () async {
    // orders has no `name` column and (before order_number was made
    // UNIQUE) no NOT NULL column either -- displayColumn fell all the way
    // through to `id` until this session's UNIQUE-column heuristic
    // (table_discovery_service.dart) and this schema fix landed together.
    final indexes = await db.rawQuery('PRAGMA index_list("orders")');
    final orderNumberIsUnique = indexes.any((i) => (i['unique'] as int) == 1);
    expect(orderNumberIsUnique, isTrue, reason: 'expected order_number TEXT UNIQUE');

    final ordersConfig = await buildOrdersConfig(discovery);
    expect(ordersConfig.displayColumn, 'order_number');
  });

  test('buildOrdersConfig sets openRowDetail and deleteWarning, standalone order_items does not', () async {
    final ordersConfig = await buildOrdersConfig(discovery);
    expect(ordersConfig.openRowDetail, isNotNull);
    expect(ordersConfig.deleteWarning, isNotNull);

    final itemsConfig = await discovery.buildConfig(orderItemsTableName);
    expect(itemsConfig.openRowDetail, isNull);
    expect(itemsConfig.deleteWarning, isNull);
  });

  test('standalone order_items config keeps order_id as a required lookup, resolving against order_number', () async {
    final itemsConfig = await discovery.buildConfig(orderItemsTableName);
    final orderId = itemsConfig.fields.firstWhere((f) => f.column == 'order_id');
    expect(orderId.isLookup, isTrue);
    expect(orderId.required, isTrue, reason: 'order_id is NOT NULL, no default');
    expect(
      orderId.lookup!.displayColumn,
      'order_number',
      reason: 'orders has no name column -- seeded field_metadata override',
    );
  });

  test('standalone order_items displayColumn resolves to description via the _display_column override', () async {
    final itemsConfig = await discovery.buildConfig(orderItemsTableName);
    expect(
      itemsConfig.displayColumn,
      'description',
      reason: 'description is nullable, so the heuristic alone would fall back to id',
    );
  });

  test('buildOrderItemsConfigForOrder strips order_id from fields and scopes reads to one order', () async {
    final orders = await db.query('orders', columns: ['id'], limit: 1);
    expect(orders, isNotEmpty, reason: 'expected real seed data (5 orders)');
    final orderId = orders.first['id'] as int;

    final scopedConfig = await buildOrderItemsConfigForOrder(discovery, orderId);
    expect(
      scopedConfig.fields.any((f) => f.column == 'order_id'),
      isFalse,
      reason: 'order_id must never be a user-facing field in the embedded split-pane context',
    );
    expect(scopedConfig.filterWhere, 'order_id = ?');
    expect(scopedConfig.filterArgs, [orderId]);

    final expected = await db.query('order_items', where: 'order_id = ?', whereArgs: [orderId]);
    final actual = await GenericDao(scopedConfig).getAll();
    expect(actual.length, expected.length);
    expect(
      actual.every((row) => row['order_id'] == orderId),
      isTrue,
      reason: 'GenericDao.getAll selects every real column (order_id included) -- the '
          'config just excludes it from fields/the form, not from what the query returns',
    );
  });

  test('an order with real items gets a specific cascade-count delete warning', () async {
    final rows = await db.rawQuery('''
      SELECT o.id, COUNT(i.id) AS item_count
      FROM orders o JOIN order_items i ON i.order_id = o.id
      GROUP BY o.id
      HAVING item_count > 0
      LIMIT 1
    ''');
    expect(rows, isNotEmpty, reason: 'expected at least one real order with items');
    final orderId = rows.first['id'];
    final itemCount = rows.first['item_count'] as int;

    final ordersConfig = await buildOrdersConfig(discovery);
    final warning = await ordersConfig.deleteWarning!({'id': orderId});
    expect(warning, contains('$itemCount'));
    expect(warning, contains('item'));
  });

  test('deleteWarning returns null (default message) for a hypothetical order with zero items', () async {
    final ordersConfig = await buildOrdersConfig(discovery);
    // -1 can never match a real order_items.order_id -- proves the
    // zero-items branch without depending on any specific real order
    // actually having zero items today.
    final warning = await ordersConfig.deleteWarning!({'id': -1});
    expect(warning, isNull);
  });
}
