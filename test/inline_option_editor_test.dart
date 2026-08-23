// Proves InlineOptionListEditor -- the repeatable key/label list editor
// AddFieldScreen/ManageFieldsScreen both use for a `select` field's
// inline option list (Essentials v2 Phase 2 build order step 4, see
// claude/essentials-v2-phase2-design.md's "Inline select" entry). Widget
// tests only, no DatabaseHelper involved -- run with
// `flutter test test/inline_option_editor_test.dart`.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/inline_option_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows existing options text in each row', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineOptionListEditor(
            options: const [InlineOption(key: 'low', label: 'Low')],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('low'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
  });

  testWidgets('empty state shows a hint instead of a blank list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InlineOptionListEditor(options: const [], onChanged: (_) {})),
      ),
    );

    expect(find.text('No options yet -- add at least one.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('Add option appends a new blank row and notifies onChanged', (tester) async {
    List<InlineOption>? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineOptionListEditor(options: const [], onChanged: (v) => last = v),
        ),
      ),
    );

    await tester.tap(find.text('Add option'));
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(2)); // Stored value + Shown as
    expect(last, hasLength(1));
    expect(last!.single.key, '');
    expect(last!.single.label, '');
  });

  testWidgets('typing into key/label fields notifies onChanged with the new text', (tester) async {
    List<InlineOption>? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineOptionListEditor(
            options: const [InlineOption(key: '', label: '')],
            onChanged: (v) => last = v,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'low');
    await tester.pump();
    expect(last!.single.key, 'low');
    expect(last!.single.label, '');

    await tester.enterText(find.byType(TextField).at(1), 'Low');
    await tester.pump();
    expect(last!.single.key, 'low');
    expect(last!.single.label, 'Low');
  });

  testWidgets('remove icon removes that row and notifies onChanged with the rest', (tester) async {
    List<InlineOption>? last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineOptionListEditor(
            options: const [
              InlineOption(key: 'low', label: 'Low'),
              InlineOption(key: 'high', label: 'High'),
            ],
            onChanged: (v) => last = v,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pump();

    expect(last, hasLength(1));
    expect(last!.single.key, 'high');
    expect(find.text('low'), findsNothing);
  });
}
