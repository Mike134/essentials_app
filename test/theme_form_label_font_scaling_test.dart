// Confirms two related, previously-unverified requirements for the
// Add/Edit form's field labels (all `floatingLabelBehavior:
// FloatingLabelBehavior.always`, see generic_form_screen.dart and every
// field-format handler's `buildFormField` -- added 2026-09-11 to make
// label sizing consistent between plain text fields and dropdown/lookup
// fields, which used to render at very different sizes):
//
// 1. Labels must scale with the device's own "Font size" setting
//    (`ThemeController.fontSizeOverride`), not stay fixed -- already true
//    before `formLabelFloatingStyle` existed (Material 3's default
//    floating label style already derives from the live, scaled theme),
//    reconfirmed here now that a custom style is in the mix.
// 2. `formLabelFloatingStyle` (`lib/util/form_label_style.dart`) must make
//    the rendered label land at ~90% of the value text's own size, not
//    Flutter's flat, non-configurable 75% -- Mike's own choice, offered
//    against "same size as the value" and "something else", after finding
//    every label uniformly small once (1) forced them all into the
//    always-floated state.
import 'package:essentials_app/theme/theme_controller.dart';
import 'package:essentials_app/util/form_label_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formLabelFloatingStyle', () {
    testWidgets('pre-compensates for the fixed 0.75x floating-label shrink to land at visibleFraction',
        (tester) async {
      const bodyLargeSize = 16.0;
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(textTheme: const TextTheme(bodyLarge: TextStyle(fontSize: bodyLargeSize))),
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      );

      // Flutter's floating label is visually shrunk by a fixed, non
      // -configurable 0.75x transform when floated (`_kFinalLabelScale`,
      // Flutter's own input_decorator.dart) -- independent of whatever
      // font size the style itself carries. So landing the on-screen
      // label at 90% of the value's size means feeding Flutter a style
      // 1/0.75 * 0.9 times bigger than the value's own bodyLarge size.
      final style = formLabelFloatingStyle(capturedContext);
      expect(style!.fontSize, closeTo(bodyLargeSize * 0.9 / 0.75, 0.001));

      final half = formLabelFloatingStyle(capturedContext, visibleFraction: 0.5);
      expect(half!.fontSize, closeTo(bodyLargeSize * 0.5 / 0.75, 0.001));
    });
  });

  testWidgets(
    "an always-floating form field label using formLabelFloatingStyle tracks ThemeController's font "
    'size setting, landing at ~90% of the value text size',
    (tester) async {
      final controller = ThemeController.instance;
      final originalOverride = controller.fontSizeOverride;
      addTearDown(() => controller.fontSizeOverride = originalOverride);

      Future<({double label, double value})> renderedSizes(double fontSizeOverride) async {
        controller.fontSizeOverride = fontSizeOverride;
        final theme = controller.themeData;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextFormField(
                  decoration: InputDecoration(
                    labelText: 'Probe Label',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    floatingLabelStyle: formLabelFloatingStyle(context),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        double? labelSize;
        for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
          final text = rt.text;
          if (text is TextSpan && text.toPlainText() == 'Probe Label') {
            labelSize = text.style!.fontSize!;
          }
        }
        if (labelSize == null) throw StateError('label RichText not found');
        // The value's own on-screen size, straight from the same live
        // theme -- avoids hardcoding Material's raw type-scale constants
        // (which live across several merged Typography tables) and ties
        // the assertion directly to what the input text actually renders
        // at under this exact fontSizeOverride.
        return (label: labelSize, value: theme.textTheme.bodyLarge!.fontSize!);
      }

      final small = await renderedSizes(10);
      final large = await renderedSizes(30);

      // Flutter's floating label is visually shrunk by a fixed 0.75x
      // transform independent of the style's own font size -- so the
      // *on-screen* label-to-value ratio is the style's fontSize ratio
      // times 0.75, which should land at Mike's chosen 0.9 regardless of
      // which fontSizeOverride is active.
      expect((small.label / small.value) * 0.75, closeTo(0.9, 0.01));
      expect((large.label / large.value) * 0.75, closeTo(0.9, 0.01));
      expect(large.label / small.label, closeTo(3.0, 0.01), reason: 'still tracks the 10 -> 30 fontSizeOverride ratio');
    },
  );
}
