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
    //
    // Two real-time windows, not one, as of Essentials v2 Phase 3:
    // ViewSwitcherBar (embedded in GenericListScreen's own AppBar as of
    // Step 2) only *mounts* once HomeShell's own `_groupsFuture` resolves
    // and rebuilds -- which can itself happen right at the edge of a single
    // delay's budget, leaving ViewSwitcherBar's own `view_definitions`
    // query starting with almost no real time left. A pending sqflite lock
    // -retry timer from that still-in-flight query then gets created in
    // the *fake* zone once `runAsync` exits, tripping flutter_test's
    // "timer still pending after dispose" invariant on teardown --
    // reproduced directly (traced to `ViewDefinitionsDao.loadViewsForTable`
    // in the failure's own stack), not a guess. The extra `pump()` +
    // second delay, both still inside `runAsync`, gives a freshly-mounted
    // widget's own async work a second real-time window instead of relying
    // on the first one covering everything that might mount partway
    // through it.
    await tester.runAsync(() async {
      await tester.pumpWidget(const EssentialsApp());
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump();
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
    // `skipOffstage: false`: the real table count has grown enough
    // (`orders`/`order_items` pushed it over) that "Settings", pinned to
    // the bottom of the rail's `ListView`, now lays out below the fixed
    // test-surface viewport -- still genuinely built, just not within the
    // default finder's onstage bounds. Same list a real window scrolls to
    // see; nothing wrong with the render, just this fixed-size test host.
    expect(find.text('Settings', skipOffstage: false), findsWidgets);
    expect(find.textContaining('Failed to load'), findsNothing);
    expect(find.textContaining('Error:'), findsNothing);
  });
}
