// Minimal smoke test -- confirms the app shell builds and shows its three
// tabs. Deliberately doesn't exercise the History/Status screens' real
// hub.db reads (Mike does his own interactive testing against the real
// database -- see CLAUDE.md "Working style / constraints"); this is just
// build verification.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:schema_admin/main.dart';

void main() {
  testWidgets('shows the three tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const SchemaAdminApp());

    expect(find.text('schema_admin'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Submit'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'History'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Status'), findsOneWidget);
  });
}
