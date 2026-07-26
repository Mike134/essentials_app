import 'package:flutter/material.dart';

import '../config/table_configs.dart';
import '../db/table_discovery_service.dart';
import '../models/table_config.dart';
import '../util/layout.dart';
import 'generic_form_screen.dart';
import 'generic_list_screen.dart';

/// Master-detail view for one `orders` row and its `order_items` --
/// CLAUDE.md "Split-Pane Layout" session, Part B. Reached only via
/// [TableConfig.openRowDetail] on `orders`' config (see `table_configs
/// .dart`'s `buildOrdersConfig`) -- opening an order from the plain
/// `orders` list pushes this instead of the default [GenericFormScreen];
/// "Add" a brand-new order still goes through the plain form (no `id` to
/// scope an items grid to yet), same as every other table.
///
/// Not true OS-level multi-window -- deliberately ruled out as unneeded
/// complexity, not a limitation worked around. One screen, responsive
/// layout, same [wideLayoutBreakpoint] switch already used for the nav
/// shell:
/// - **Wide (Windows):** [Row] -- Order form left, Items grid right, both
///   live simultaneously, no navigation between them. The order form saves
///   in place ([GenericFormScreen.popOnSave] false) rather than popping.
/// - **Narrow (Android):** Order form full-screen; its AppBar gets an
///   extra "Items" action ([GenericFormScreen.appBarActions]) that pushes
///   a full-screen `order_items` list; tapping an item opens its own form;
///   back returns to the Order.
///
/// Either layout's items grid is [GenericListScreen] with a config built by
/// [buildOrderItemsConfigForOrder] -- `order_id` stripped from its fields
/// (never a user-facing column here) and [TableConfig.filterWhere] scoping
/// reads to this order, with [GenericListScreen.formExtraValues] silently
/// supplying `order_id` on insert.
class OrderSplitPaneScreen extends StatefulWidget {
  const OrderSplitPaneScreen({super.key, required this.orderConfig, required this.order});

  /// `orders`' own discovered [TableConfig] -- reused directly for the
  /// embedded/full-screen order form.
  final TableConfig orderConfig;

  /// The order row being viewed/edited. Always non-null -- this screen is
  /// only ever reached via [TableConfig.openRowDetail], which is only
  /// called for an existing row (see its doc comment).
  final Map<String, Object?> order;

  @override
  State<OrderSplitPaneScreen> createState() => _OrderSplitPaneScreenState();
}

class _OrderSplitPaneScreenState extends State<OrderSplitPaneScreen> {
  late final Future<TableConfig> _itemsConfigFuture;

  @override
  void initState() {
    super.initState();
    _itemsConfigFuture = buildOrderItemsConfigForOrder(
      TableDiscoveryService(),
      widget.order['id'] as int,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TableConfig>(
      future: _itemsConfigFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(body: Center(child: Text('Error: ${snapshot.error}')));
        }
        final itemsConfig = snapshot.data;
        if (itemsConfig == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= wideLayoutBreakpoint;

            if (isWide) {
              return Row(
                children: [
                  Expanded(
                    child: GenericFormScreen(
                      config: widget.orderConfig,
                      existing: widget.order,
                      popOnSave: false,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: GenericListScreen(
                      config: itemsConfig,
                      formExtraValues: {'order_id': widget.order['id']},
                    ),
                  ),
                ],
              );
            }

            return GenericFormScreen(
              config: widget.orderConfig,
              existing: widget.order,
              appBarActions: [
                IconButton(
                  icon: const Icon(Icons.list_alt),
                  tooltip: 'Items',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => GenericListScreen(
                        config: itemsConfig,
                        formExtraValues: {'order_id': widget.order['id']},
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
