import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:essentials_app/main.dart';

void main() {
  setUpAll(() {
    // DatabaseHelper picks databaseFactoryFfi itself on Windows (which is
    // where `flutter test` actually runs), but sqlite3's native lib still
    // needs this one-time init call.
    sqfliteFfiInit();
  });

  testWidgets('EssentialsApp renders the nav shell without error', (WidgetTester tester) async {
    // The startup table-discovery/grouping query is real async DB I/O,
    // which needs genuine wall-clock time to complete -- pumpAndSettle's
    // fake clock never lets it resolve, so it just times out waiting on
    // the FutureBuilder's spinner.
    await tester.runAsync(() async {
      await tester.pumpWidget(const EssentialsApp());
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    // Was `expect(find.text('Domain'), findsWidgets)` -- fragile against
    // real, mutable production state (CLAUDE.md "Table Discovery phase"):
    // once every table (not just batch 1) resolves through discovery, nav
    // order stopped guaranteeing `domain` renders first, and it can also
    // land inside a collapsed sidebar group -- the rail is a lazily-built
    // `ListView`, so a table inside a collapsed or off-screen group simply
    // has no Text widget in the tree at all, real bug or not. Assert
    // something structurally guaranteed instead: "Settings" always renders
    // (bottom of the rail, never grouped/collapsed), and no error text
    // appeared (catches the exact failure mode the empty-db incident
    // exposed -- see CLAUDE.md "Sync architecture" -- a thrown exception
    // silently read as "still loading" instead of a visible error).
    expect(find.text('Settings'), findsWidgets);
    expect(find.textContaining('Failed to load'), findsNothing);
    expect(find.textContaining('Error:'), findsNothing);
  });
}
