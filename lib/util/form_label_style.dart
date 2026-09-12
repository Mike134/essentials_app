import 'package:flutter/material.dart';

/// The floating-label text style for every field in the Add/Edit record
/// form ([GenericFormScreen]) and every [FieldFormatHandler.buildFormField]
/// it delegates to -- all of them use `floatingLabelBehavior:
/// FloatingLabelBehavior.always` (2026-09-11, to make dropdown/lookup
/// labels and plain text-field labels render at a consistent size, where
/// before a dropdown's label was always small/floated while an empty text
/// field's sat at full size until focused or filled).
///
/// **Why this exists instead of just using the default floating label
/// style:** Flutter's Material 3 default already derives the label from
/// the live theme (`Theme.of(context).textTheme.bodyLarge`, so it already
/// tracks the app's own font-size setting -- confirmed directly, see
/// `test/theme_form_label_font_scaling_test.dart`), but it also always
/// visually shrinks a floated label by a fixed, non-configurable 0.75x
/// transform (`_kFinalLabelScale` in Flutter's `input_decorator.dart`) --
/// independent of whatever font size the style itself carries. Once every
/// label was forced into that always-floated state for the consistency fix
/// above, every label ended up a flat 75% of the value text's size, which
/// Mike found looked washed-out/too small next to the (unshrunk) value.
///
/// The fix is to feed Flutter a *larger* style than the value's own, so
/// that after its own fixed 0.75x shrink, the label lands at
/// [visibleFraction] of the value's actual on-screen size instead of a
/// flat 75% -- i.e. pre-compensate for a transform this app has no other
/// way to disable or adjust. `visibleFraction: 0.9` was Mike's own choice
/// (offered against "same size as the value" and "something else").
TextStyle? formLabelFloatingStyle(BuildContext context, {double visibleFraction = 0.9}) {
  final base = Theme.of(context).textTheme.bodyLarge;
  final fontSize = base?.fontSize;
  if (fontSize == null) return base;
  return base!.copyWith(fontSize: fontSize * visibleFraction / 0.75);
}
