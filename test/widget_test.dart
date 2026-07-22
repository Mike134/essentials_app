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

  testWidgets('EssentialsApp renders the domain list', (WidgetTester tester) async {
    // The domain query is real async DB I/O, which needs genuine wall-clock
    // time to complete -- pumpAndSettle's fake clock never lets it resolve,
    // so it just times out waiting on the FutureBuilder's spinner.
    await tester.runAsync(() async {
      await tester.pumpWidget(const EssentialsApp());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    // The default test surface is wide (800x600), so both the
    // NavigationRail's label and the list screen's AppBar title say
    // "Domain" -- that's two matches, not a bug.
    expect(find.text('Domain'), findsWidgets);
  });
}
