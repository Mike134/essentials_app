// Regression proof for CLAUDE.md "Table Discovery phase" Part E.3: the
// last hand-written TableConfig, subscriptionConfig, is gone -- replaced by
// buildSubscriptionConfig, which introspects the real subscription table
// (like every other converted table) and layers subscription's two genuine
// exceptions on top: the payment_method_id -> account.code lookup override
// (seeded field_metadata, tool/seed_field_metadata_subscription.dart) and
// the subscription_computed view (yearly_cost/next_date, readSource,
// computePreview -- neither expressible as data). Run with
// `flutter test test/subscription_conversion_regression_test.dart`.
//
// Against the real db, not a fixture -- read-only, never creates/drops/
// mutates anything.
import 'package:essentials_app/config/table_configs.dart';
import 'package:essentials_app/db/database_helper.dart';
import 'package:essentials_app/db/generic_dao.dart';
import 'package:essentials_app/db/table_discovery_service.dart';
import 'package:essentials_app/models/table_config.dart';
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

  test('matches its exact pre-conversion field order and shape', () async {
    final config = await buildSubscriptionConfig(discovery);

    expect(config.tableName, 'subscription');
    expect(config.displayColumn, 'name');
    expect(config.readSource, 'subscription_computed');
    expect(config.computePreview, isNotNull);

    // Exact original field order, including the two injected view-only
    // columns at the exact position they held before conversion.
    expect(config.fields.map((f) => f.column).toList(), [
      'name',
      'domain_id',
      'used_by_id',
      'class_id',
      'renewal_period_id',
      'cost',
      'yearly_cost',
      'payment_method_id',
      'importance_id',
      'disposition_id',
      'start_date',
      'next_date',
      'last_date',
      'link',
      'active',
      'note',
    ]);
  });

  test('labels match, including the two that needed the _id-stripping heuristic', () async {
    final config = await buildSubscriptionConfig(discovery);
    final byColumn = {for (final f in config.fields) f.column: f};

    expect(byColumn['used_by_id']!.label, 'Used By');
    expect(byColumn['renewal_period_id']!.label, 'Renewal Period');
    expect(byColumn['payment_method_id']!.label, 'Payment Method');
    expect(byColumn['domain_id']!.label, 'Domain');
    expect(byColumn['class_id']!.label, 'Class');
    expect(byColumn['importance_id']!.label, 'Importance');
    expect(byColumn['disposition_id']!.label, 'Disposition');
  });

  test('payment_method_id resolves against account.code, not account.name', () async {
    final config = await buildSubscriptionConfig(discovery);
    final paymentMethod = config.fields.firstWhere((f) => f.column == 'payment_method_id');
    expect(paymentMethod.isLookup, isTrue);
    expect(paymentMethod.lookup!.table, 'account');
    expect(
      paymentMethod.lookup!.displayColumn,
      'code',
      reason: 'from the seeded field_metadata override -- account genuinely has its own name '
          'column, so the default heuristic would otherwise pick that instead',
    );
  });

  test('yearly_cost/next_date are readOnly, real fields are not', () async {
    final config = await buildSubscriptionConfig(discovery);
    final byColumn = {for (final f in config.fields) f.column: f};

    expect(byColumn['yearly_cost']!.readOnly, isTrue);
    expect(byColumn['yearly_cost']!.type, FieldType.real);
    expect(byColumn['next_date']!.readOnly, isTrue);
    expect(byColumn['next_date']!.type, FieldType.date);

    expect(byColumn['cost']!.readOnly, isFalse);
    expect(byColumn['start_date']!.readOnly, isFalse);
  });

  test('active default comes from the real SQL DEFAULT 1, no override needed', () async {
    final config = await buildSubscriptionConfig(discovery);
    final active = config.fields.firstWhere((f) => f.column == 'active');
    expect(active.type, FieldType.boolean);
    expect(active.defaultValue, true);
  });

  test(
    'GenericDao.getAll (via readSource) returns yearly_cost/next_date matching a direct '
    'query against subscription_computed for every real row',
    () async {
      final config = await buildSubscriptionConfig(discovery);
      final dao = GenericDao(config);

      final viaConfig = await dao.getAll();
      final viaDirectQuery = await db.query('subscription_computed');

      expect(viaConfig.length, viaDirectQuery.length);

      final directById = {for (final row in viaDirectQuery) row['id'] as int: row};
      for (final row in viaConfig) {
        final id = row['id'] as int;
        final direct = directById[id]!;
        expect(row['yearly_cost'], direct['yearly_cost'], reason: 'row id $id');
        expect(row['next_date'], direct['next_date'], reason: 'row id $id');
      }
    },
  );

  test('payment_method_id lookup options render account.code, not account.name', () async {
    final config = await buildSubscriptionConfig(discovery);
    final dao = GenericDao(config);
    final paymentMethod = config.fields.firstWhere((f) => f.column == 'payment_method_id');

    final options = await dao.getLookupOptions(paymentMethod.lookup!);
    final directCodes = await db.query('account', columns: ['id', 'code']);

    final optionsById = {for (final o in options) o['id'] as int: o['code']};
    for (final row in directCodes) {
      expect(optionsById[row['id']], row['code']);
    }
  });
}
