import 'dart:async';

import 'package:flutter/material.dart';

import '../config/table_configs.dart';
import '../db/table_discovery_service.dart';
import '../db/theme_settings_dao.dart';
import '../models/table_config.dart';
import '../util/device_id.dart';
import '../util/layout.dart';
import 'generic_form_screen.dart';
import 'generic_list_screen.dart';

/// Per-device (not per-order -- CLAUDE.md's governing rule for column
/// widths/order/etc. applies the same way here: how much space Mike wants
/// the form vs. the items grid on *this device* is a per-screen-type
/// preference, not a fact about any one order), keyed by table, not
/// record -- every order on a given device shares the same remembered
/// split. [ThemeSettingsDao.loadDeviceSetting]/[setDeviceSetting] is
/// already the generic `device_settings` key/value accessor this app
/// reuses for exactly this kind of one-off per-device setting (font size,
/// grid row heights) -- no new dao needed.
const String _splitRatioKey = 'order_split_pane_ratio';

const double _minSplitRatio = 0.25;
const double _maxSplitRatio = 0.75;
const double _defaultSplitRatio = 0.5;
const double _dividerWidth = 8;

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
  /// Debounce between the last divider drag frame and actually persisting
  /// it -- same reasoning as [GenericListScreen]'s column-resize debounce:
  /// a drag fires many updates per frame, and a synced-db write per frame
  /// is wasteful when only the position on drag-release matters.
  static const Duration _saveDebounce = Duration(milliseconds: 500);

  late final Future<_SplitPaneData> _dataFuture;
  ThemeSettingsDao? _settingsDao;
  double _splitRatio = _defaultSplitRatio;
  bool _seeded = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_SplitPaneData> _loadData() async {
    final itemsConfig = buildOrderItemsConfigForOrder(
      TableDiscoveryService(),
      widget.order['id'] as int,
    );
    final deviceId = await DeviceId.resolve();
    final settingsDao = ThemeSettingsDao(deviceId: deviceId);
    final savedRatio = await settingsDao.loadDeviceSetting(_splitRatioKey);
    return _SplitPaneData(
      itemsConfig: await itemsConfig,
      settingsDao: settingsDao,
      initialSplitRatio: double.tryParse(savedRatio ?? '') ?? _defaultSplitRatio,
    );
  }

  void _onDividerDrag(DragUpdateDetails details, double totalWidth) {
    setState(() {
      _splitRatio = (_splitRatio + details.delta.dx / totalWidth).clamp(
        _minSplitRatio,
        _maxSplitRatio,
      );
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      _settingsDao?.setDeviceSetting(_splitRatioKey, _splitRatio.toString());
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_SplitPaneData>(
      future: _dataFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(body: Center(child: Text('Error: ${snapshot.error}')));
        }
        final data = snapshot.data;
        if (data == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        _settingsDao = data.settingsDao;
        final itemsConfig = data.itemsConfig;

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= wideLayoutBreakpoint;

            if (isWide) {
              // First build after load: seed the live ratio from what was
              // saved. A later rebuild (e.g. window resize) must not
              // re-seed it -- that would stomp an in-progress drag with the
              // stale saved value.
              if (!_seeded) {
                _splitRatio = data.initialSplitRatio;
                _seeded = true;
              }
              final availableWidth = constraints.maxWidth - _dividerWidth;
              final leftWidth = availableWidth * _splitRatio;
              final rightWidth = availableWidth - leftWidth;

              return Row(
                children: [
                  SizedBox(
                    width: leftWidth,
                    child: GenericFormScreen(
                      config: widget.orderConfig,
                      existing: widget.order,
                      popOnSave: false,
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) =>
                          _onDividerDrag(details, availableWidth),
                      child: SizedBox(
                        width: _dividerWidth,
                        child: VerticalDivider(width: _dividerWidth, thickness: 1),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: rightWidth,
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

/// Everything one [_OrderSplitPaneScreenState.build] needs from its initial
/// load -- the scoped items config plus this device's saved divider
/// position (or [_defaultSplitRatio] if nothing's been saved yet).
class _SplitPaneData {
  const _SplitPaneData({
    required this.itemsConfig,
    required this.settingsDao,
    required this.initialSplitRatio,
  });

  final TableConfig itemsConfig;
  final ThemeSettingsDao settingsDao;
  final double initialSplitRatio;
}
