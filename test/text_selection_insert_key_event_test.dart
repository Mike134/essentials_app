// Proves the *wiring* the Enter-key fix depends on: a FocusNode's own
// onKeyEvent callback (the mechanism GenericFormScreen._handleFieldKeyEvent
// uses) really is reachable via a real key event dispatched at the
// TextFormField it's attached to, and really does let insertAtSelection
// take over from Flutter's own (broken, on Windows -- see
// generic_form_screen.dart's own write-up) native Enter/newline handling.
// This can't exercise the actual native-IME failure this fix works around
// (flutter_test's TestTextInput is a synthetic double, not the real
// platform text input channel -- see this file's own probe history in the
// session that added this fix), but it does prove the Dart-side mechanism
// itself is sound: the FocusNode receives the event, KeyEventResult.handled
// is returned, and the controller ends up with a real newline. Pure widget
// test, no database -- run with
// `flutter test test/text_selection_insert_key_event_test.dart`.
import 'package:essentials_app/util/text_selection_insert.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a FocusNode.onKeyEvent handler intercepts Enter and inserts a real newline', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final isEnter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (!isEnter) return KeyEventResult.ignored;
        controller.value = insertAtSelection(controller.value, '\n');
        return KeyEventResult.handled;
      },
    );
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextFormField(controller: controller, focusNode: focusNode, maxLines: null),
        ),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), '1. test');
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Simulates the IME appending "2. another" after the cursor, exactly
    // as real typing would continue from wherever insertAtSelection left
    // the (now-collapsed) selection.
    await tester.enterText(find.byType(TextFormField), '${controller.text}2. another');
    await tester.pumpAndSettle();

    expect(controller.text, '1. test\n2. another');
  });

  testWidgets('a plain TextFormField with no onKeyEvent handler does not gain a newline from Enter alone', (
    tester,
  ) async {
    // The control case -- confirms the *previous* behavior (before this
    // fix) really would leave Enter a no-op in this exact test harness,
    // so the test above is actually proving something, not passing by
    // construction.
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextFormField(controller: controller, maxLines: null)),
      ),
    );

    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '1. test');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text.contains('\n'), isFalse);
  });
}
