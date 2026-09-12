import 'package:flutter/material.dart';

/// One icon/label per `view_definitions.view_type` -- shared by every place
/// that renders a view generically by type: [ViewSwitcherBar]'s own tab
/// chips (Mike's own ask: "should be obvious" which tab is which, matching
/// the icon touch already given to Filter Set buttons), `ManageViewsScreen`'s
/// list, and `_NewViewDialog`'s own type picker (though that one still
/// declares its two icons directly alongside its `ButtonSegment` labels --
/// not worth threading through here for just two literals used once).
IconData viewTypeIcon(String viewType) => switch (viewType) {
  'kanban' => Icons.view_column_outlined,
  'filter' => Icons.filter_alt_outlined,
  _ => Icons.view_list_outlined,
};

String viewTypeLabel(String viewType) => switch (viewType) {
  'kanban' => 'Kanban',
  'filter' => 'Filter Set',
  _ => 'List',
};
