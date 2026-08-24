import 'dart:async';

import 'package:flutter/widgets.dart';

import '../db/generic_dao.dart';
import '../models/table_config.dart';

/// Debounced, live-`SELECT DISTINCT`-backed suggestion source for a
/// [FieldConfig.isAutocompleteText] field -- shared by [GenericFormScreen]
/// and [GenericListScreen] so both surfaces behave identically, per
/// claude/essentials-v2-column-autocomplete-design.md.
///
/// Callable directly as a [RawAutocomplete]/[Autocomplete] `optionsBuilder`
/// -- confirmed against the installed Flutter SDK that this typedef is
/// `FutureOr<Iterable<T>> Function(TextEditingValue)`, not a synchronous
/// one, so the DAO query runs for real on every call rather than needing a
/// synchronous-cache workaround. [RawAutocomplete]'s own internal
/// `_onChangedField` already guards against a slow, superseded call
/// clobbering a faster, newer one by call-id -- this class debounces on
/// top of that (~200ms, per the design doc) so a query doesn't fire on
/// every keystroke: each call waits out the window and bails out early
/// (returning nothing) the moment a newer call has since started, so only
/// the freshest call's query actually reaches the database.
class ColumnAutocompleteSource {
  ColumnAutocompleteSource({required this.dao, required this.field, required this.excludeValue});

  final GenericDao dao;
  final FieldConfig field;

  /// The value already sitting in the cell/field being edited -- excluded
  /// from the results (see [GenericDao.getDistinctColumnValues]'s
  /// `excludeValue`) so a field showing exactly what's already typed isn't
  /// suggested back at itself. Read live on every call, not captured once,
  /// so it stays correct as the user edits.
  final String? Function() excludeValue;

  static const _debounce = Duration(milliseconds: 200);

  int _requestId = 0;

  Future<Iterable<String>> call(TextEditingValue value) async {
    final requestId = ++_requestId;
    final prefix = value.text;
    if (prefix.isEmpty) return const [];

    await Future<void>.delayed(_debounce);
    if (requestId != _requestId) return const [];

    return dao.getDistinctColumnValues(
      dao.config.tableName,
      field.column,
      prefix: prefix,
      excludeValue: excludeValue(),
    );
  }
}
