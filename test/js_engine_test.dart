// Essentials v2 Phase 5 build order step 2. Real, permanent regression
// coverage for the empirical findings recorded in JsEngine's own doc
// comment -- run this against the actual QuickJS runtime, not mocked,
// same discipline as every other "verify live, don't assume" test in
// this project.
//
// **Toolchain note, not a code issue:** `flutter build windows`/`flutter
// build apk` both correctly bundle flutter_js's native shared library
// (`quickjs_c_bridge.dll` on Windows) via CMake/Gradle's own plugin
// bundling step -- `flutter test` does NOT, since it runs a plain
// console test host with no plugin-bundling step of its own. Running
// this file locally therefore needs `quickjs_c_bridge.dll` copied from a
// prior `flutter build windows` output
// (`build\windows\x64\runner\Release\quickjs_c_bridge.dll`) into the repo
// root first, or `dart:ffi`'s `DynamicLibrary.open('quickjs_c_bridge.dll')`
// fails outright with "The specified module could not be found." This
// mirrors the project's other native-plugin-vs-flutter-test frictions
// (see CLAUDE.md's `sqlite3_flutter_libs` history) -- not something to
// "fix" in this file, just something to remember before re-running it.
import 'package:essentials_app/util/scripting/js_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a normal script returns its final value quickly', () async {
    final engine = JsEngine(timeout: const Duration(seconds: 5));
    final outcome = await engine.run('1 + 1');
    expect(outcome.succeeded, isTrue);
    expect(outcome.timedOut, isFalse);
    expect(outcome.value, '2');
  });

  test('a thrown JS error is reported as a failure, not a timeout', () async {
    final engine = JsEngine(timeout: const Duration(seconds: 5));
    final outcome = await engine.run("throw new Error('boom')");
    expect(outcome.succeeded, isFalse);
    expect(outcome.timedOut, isFalse);
    expect(outcome.error, contains('boom'));
  });

  test('a genuine infinite loop reports timedOut and the caller unblocks promptly', () async {
    final engine = JsEngine(timeout: const Duration(seconds: 1));
    final stopwatch = Stopwatch()..start();
    final outcome = await engine.run('while (true) {}');
    stopwatch.stop();

    expect(outcome.timedOut, isTrue);
    expect(outcome.succeeded, isFalse);
    // The load-bearing guarantee: the caller returns close to `timeout`,
    // not never -- confirmed empirically (see JsEngine's own doc
    // comment), not assumed from flutter_js's own docs/changelog.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a syntax error is reported as a failure', () async {
    final engine = JsEngine();
    final outcome = await engine.run('this is not valid js (((');
    expect(outcome.succeeded, isFalse);
    expect(outcome.timedOut, isFalse);
    expect(outcome.error, isNotNull);
  });
}
