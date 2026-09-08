// `table_definitions.icon` -- a small tagged-string convention, not a new
// schema column (the column already existed, unused, since Essentials v2
// Phase 1's New Table screen: "stored for later use"). Two shapes:
//
// - `material:<name>` -- a built-in Material icon, <name> a key into
//   materialTableIconCatalog. No arbitrary icon-font name is ever accepted
//   -- same "curated list, not free text" call this project already made
//   for font family (see ThemePreset's own doc comment): nothing is
//   bundled beyond Flutter's built-in Material icon font, so an arbitrary
//   name would just silently render as nothing.
// - `image:<relative_key>` -- a custom uploaded image, <relative_key> the
//   same `{table}/{record_id}/{field_name}/{filename}` shape the image
//   field format already uses, resolved via FileSyncService. The table
//   icon isn't itself a record, so `record_id` is the real physical
//   `table_name` this icon belongs to and `field_name` is the fixed
//   tableIconFieldName -- see tableIconFileTable's own doc comment.
//
// `null`/anything else unrecognized means "no icon" -- callers fall back
// to whatever generic default they already render (never an error state).

import 'package:flutter/material.dart';

/// Synthetic `table` segment for a table icon's [FileSyncService] key --
/// not a real table in `essentials.db`. The hub's `/files/...` endpoint
/// never validates this segment against real schema (confirmed by reading
/// `server/bin/server.dart`'s `_handleFilesRequest`: it only checks each
/// path segment is a safe filesystem name, nothing about what "table"
/// means), so a synthetic namespace here is exactly as safe as a real
/// table name would be -- it just keeps a table's own icon file physically
/// separate from any real record's own image-field files.
const tableIconFileTable = '_table_icons';

/// Fixed `field_name` segment for a table icon's file key -- there's only
/// ever one icon per table, so this never needs to vary the way a real
/// image field's own column name would.
const tableIconFieldName = 'icon';

/// Extensions accepted for a custom table icon image -- mirrors
/// `GenericFormScreen`'s own `_recognizedImageExtensions` (kept as a
/// separate constant here rather than importing that file's private one,
/// same small-duplication convention already used elsewhere in this app
/// for values that need to be reachable from more than one file).
const recognizedTableIconExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp', '.gif'};

String encodeMaterialTableIcon(String name) => 'material:$name';

String encodeImageTableIcon(String relativeKey) => 'image:$relativeKey';

/// The Material icon name encoded in [raw], or `null` if [raw] isn't a
/// recognized `material:` icon (including an unrecognized name -- a
/// catalog entry removed in a future version of this app shouldn't crash
/// an existing table, just fall back to no icon).
String? materialIconNameFor(String? raw) {
  if (raw == null || !raw.startsWith('material:')) return null;
  final name = raw.substring('material:'.length);
  return materialTableIconCatalog.containsKey(name) ? name : null;
}

IconData? materialIconDataFor(String? raw) {
  final name = materialIconNameFor(raw);
  return name == null ? null : materialTableIconCatalog[name];
}

/// The relative file key encoded in [raw], or `null` if [raw] isn't an
/// `image:` icon.
String? imageIconKeyFor(String? raw) {
  if (raw == null || !raw.startsWith('image:')) return null;
  final key = raw.substring('image:'.length);
  return key.isEmpty ? null : key;
}

/// Curated built-in icon choices -- same "a picker full of options that
/// all look the same isn't worth the free-text alternative" reasoning as
/// font family. Broad, general-purpose categories rather than anything
/// domain-specific, since this app has no fixed notion of what kinds of
/// tables Mike will ever create.
const materialTableIconCatalog = <String, IconData>{
  'table': Icons.table_chart_outlined,
  'list': Icons.list_alt_outlined,
  'folder': Icons.folder_outlined,
  'star': Icons.star_outline,
  'label': Icons.label_outline,
  'bookmark': Icons.bookmark_outline,
  'flag': Icons.flag_outlined,
  'person': Icons.person_outline,
  'people': Icons.people_outline,
  'contact': Icons.contact_page_outlined,
  'home': Icons.home_outlined,
  'business': Icons.business_outlined,
  'work': Icons.work_outline,
  'school': Icons.school_outlined,
  'shopping_cart': Icons.shopping_cart_outlined,
  'shopping_bag': Icons.shopping_bag_outlined,
  'store': Icons.storefront_outlined,
  'inventory': Icons.inventory_2_outlined,
  'receipt': Icons.receipt_long_outlined,
  'attach_money': Icons.attach_money,
  'account_balance': Icons.account_balance_outlined,
  'credit_card': Icons.credit_card_outlined,
  'savings': Icons.savings_outlined,
  'subscriptions': Icons.subscriptions_outlined,
  'calendar': Icons.calendar_month_outlined,
  'event': Icons.event_outlined,
  'schedule': Icons.schedule_outlined,
  'task': Icons.task_alt_outlined,
  'checklist': Icons.checklist_outlined,
  'notes': Icons.notes_outlined,
  'description': Icons.description_outlined,
  'book': Icons.menu_book_outlined,
  'movie': Icons.movie_outlined,
  'music': Icons.music_note_outlined,
  'photo': Icons.photo_outlined,
  'video': Icons.videocam_outlined,
  'games': Icons.sports_esports_outlined,
  'fitness': Icons.fitness_center_outlined,
  'restaurant': Icons.restaurant_outlined,
  'local_cafe': Icons.local_cafe_outlined,
  'car': Icons.directions_car_outlined,
  'flight': Icons.flight_outlined,
  'place': Icons.place_outlined,
  'map': Icons.map_outlined,
  'health': Icons.health_and_safety_outlined,
  'medical': Icons.medical_services_outlined,
  'pets': Icons.pets_outlined,
  'garden': Icons.local_florist_outlined,
  'tools': Icons.build_outlined,
  'devices': Icons.devices_outlined,
  'code': Icons.code_outlined,
  'lock': Icons.lock_outline,
  'key': Icons.vpn_key_outlined,
  'inbox': Icons.inbox_outlined,
  'mail': Icons.mail_outline,
  'phone': Icons.phone_outlined,
  'link': Icons.link_outlined,
  'category': Icons.category_outlined,
  'archive': Icons.archive_outlined,
  'timeline': Icons.timeline_outlined,
  'insights': Icons.insights_outlined,
  'lightbulb': Icons.lightbulb_outline,
};
