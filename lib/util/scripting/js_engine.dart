import 'dart:async';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';

/// Outcome of one script execution -- see
/// claude/essentials-v2-phase5-design.md's "Script safety" (confirmed
/// posture: timeout + catch + notify). Exactly one of [value]/[error] is
/// meaningful when [succeeded]/[timedOut] say so; check [timedOut] first.
class JsExecutionOutcome {
  const JsExecutionOutcome._({this.value, this.error, this.timedOut = false});

  factory JsExecutionOutcome.ok(String? value) => JsExecutionOutcome._(value: value);
  factory JsExecutionOutcome.failure(String error) => JsExecutionOutcome._(error: error);
  // Deliberately NOT a redirecting `const factory ... = JsExecutionOutcome._;`
  // -- a redirect with no declared parameters forwards none to the target
  // either, which would silently default `timedOut` back to `false` (a
  // real bug caught by this class's own test, not theorized).
  factory JsExecutionOutcome.timeout() => const JsExecutionOutcome._(timedOut: true);

  /// The script's final expression value, stringified by QuickJS itself
  /// (`JsEvalResult.stringResult`) -- `null` on failure/timeout.
  final String? value;

  /// A thrown JS error's message, or a Dart-side failure (e.g. the
  /// isolate itself failed to spawn) -- `null` on success/timeout.
  final String? error;

  /// True if the script did not finish within [JsEngine.timeout]. See
  /// [JsEngine]'s own doc comment for exactly what "timed out" can and
  /// can't guarantee about the underlying execution actually stopping.
  final bool timedOut;

  bool get succeeded => !timedOut && error == null;
}

/// Minimal wrapper around `flutter_js`'s QuickJS runtime -- the one place
/// Essentials v2 Phase 5's "Script safety" decision (timeout + catch +
/// notify) and the interrupt-hook question it depends on are resolved.
/// Every later Phase 5 piece (the `record`/`table`/`notify`/`navigate`
/// script API, event wiring, scheduled execution) runs scripts through
/// this class, never `QuickJsRuntime2` directly.
///
/// **Real, empirically confirmed finding -- NOT what the source/changelog
/// reading suggested going in.** `QuickJsRuntime2`'s `timeout` (ms)
/// constructor parameter is passed straight into the native `jsNewRuntime`
/// FFI call, and the package's own changelog (0.7.2: "upgraded quickjs
/// code to allow set timeout") strongly implied a real QuickJS-level
/// `JS_SetInterruptHandler`-style interrupt. **A live test proved this
/// wrong**: `QuickJsRuntime2(timeout: 500).evaluate('while (true) {}')`
/// did not return -- it hung the whole `flutter test` process until an
/// external, process-level timeout killed it (see git history on this
/// file's neighboring test for the exact repro). Whatever this installed
/// version's `timeout` actually gates, it is NOT the synchronous
/// interpreter loop. Do not re-introduce a "just pass `timeout:` and
/// trust it" design without re-verifying against whatever version is
/// installed at the time.
///
/// **The actual, verified safety mechanism: isolate abandonment, not
/// interruption.** Every [run] spawns the script onto its own throwaway
/// [Isolate] and races that isolate's reply against a Dart-side
/// [Future.timeout] on the *caller's* side. A second live test confirmed
/// the property that actually matters: the caller reliably unblocks at
/// the configured timeout **even when the spawned isolate is
/// permanently, unrecoverably stuck** in a genuine infinite loop --
/// because the isolate's blocking native FFI call cannot be preempted by
/// Dart (an isolate boundary doesn't stop an in-flight synchronous native
/// call the way it stops a busy pure-Dart loop), but it *does* mean that
/// stuck call runs on a thread that is not the caller's, so the caller
/// (in production: the main app isolate) never freezes. **The honest
/// limitation, not hidden:** a script that hangs forever leaks its
/// isolate/OS thread rather than being cleanly reclaimed -- this class
/// calls [Isolate.kill] on timeout as a best-effort cleanup (it takes
/// effect immediately for any isolate not currently blocked in native
/// code, and is a no-op for one that is), but cannot guarantee the
/// underlying thread is ever actually freed for a truly-hung script. This
/// matches the design doc's own framing exactly: "the user-facing
/// behavior (kill, log, notify) stays the same -- this only affects how
/// 'kill' is actually implemented." A script that hangs is rare (it
/// requires a genuine infinite loop with no I/O/timer yield point,
/// something a legitimate automation script has no reason to contain);
/// this design accepts that rare cost in exchange for a guarantee that
/// actually holds: the app itself never freezes because of it.
class JsEngine {
  JsEngine({this.timeout = const Duration(seconds: 5)});

  /// Max time a script may run before being treated as hung. Applies to
  /// the caller's own wait, not (per the finding above) a guaranteed bound
  /// on the spawned isolate's own execution time.
  final Duration timeout;

  /// Runs [code] to completion, or reports [JsExecutionOutcome.timeout]
  /// once [timeout] elapses without a reply. [code] must be a plain JS
  /// expression/statement sequence exercising only what a bare QuickJS
  /// runtime exposes by default (console.log, setTimeout, JSON, ...) --
  /// no `record`/`table`/`notify`/`navigate` bridge exists at this layer.
  /// That real script API (build order step 3) is a thin layer on top of
  /// this class's isolate boundary, not built here.
  Future<JsExecutionOutcome> run(String code) async {
    final port = ReceivePort();
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(_runInIsolate, _IsolateRequest(code, port.sendPort));
    } catch (e) {
      port.close();
      return JsExecutionOutcome.failure('Failed to start script isolate: $e');
    }

    try {
      final message = await port.first.timeout(timeout);
      if (message is _IsolateFailure) {
        return JsExecutionOutcome.failure(message.error);
      }
      return JsExecutionOutcome.ok((message as _IsolateSuccess).value);
    } on TimeoutException {
      return JsExecutionOutcome.timeout();
    } finally {
      port.close();
      // Best-effort only -- see this class's own doc comment for why this
      // cannot be relied on to actually reclaim a genuinely hung script's
      // isolate/thread.
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

class _IsolateRequest {
  const _IsolateRequest(this.code, this.replyTo);
  final String code;
  final SendPort replyTo;
}

class _IsolateSuccess {
  const _IsolateSuccess(this.value);
  final String? value;
}

class _IsolateFailure {
  const _IsolateFailure(this.error);
  final String error;
}

/// Runs on the spawned isolate -- must not touch anything from the parent
/// isolate's memory (Dart isolates share nothing but message-passed
/// data), and must not assume Flutter's platform-channel binding is
/// available (it isn't, on a non-main isolate) -- `QuickJsRuntime2` is
/// pure `dart:ffi`, confirmed by reading its source, so this holds.
void _runInIsolate(_IsolateRequest request) {
  QuickJsRuntime2? runtime;
  try {
    runtime = QuickJsRuntime2(timeout: 0);
    final result = runtime.evaluate(request.code);
    if (result.isError) {
      request.replyTo.send(_IsolateFailure(result.stringResult));
    } else {
      request.replyTo.send(_IsolateSuccess(result.stringResult));
    }
  } catch (e) {
    request.replyTo.send(_IsolateFailure(e.toString()));
  } finally {
    runtime?.dispose();
  }
}
