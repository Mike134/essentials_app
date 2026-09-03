import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'background_schedule_service.dart';

/// Essentials v2 Phase 5 build order step 8 -- the flag `main.dart`
/// checks for. A Windows Scheduled Task launches `essentials_app.exe
/// --background-schedule-check`; `windows/runner/main.cpp` still creates
/// a real window (there is no headless Flutter engine on Windows the way
/// Android's `workmanager` gives one -- confirmed via a real spike, see
/// claude/essentials-v2-phase5-design.md's step 8 write-up) but hides it
/// immediately, before the Dart side ever runs. `main()` checks this same
/// flag and calls [runWindowsBackgroundScheduleCheck] instead of ever
/// building `EssentialsApp`/calling `runApp` -- no visible UI is ever
/// shown, on purpose.
const backgroundScheduleCheckArg = '--background-schedule-check';

/// Native quit path wired up by `flutter_window.cpp` (only when the
/// window is created with `suppress_auto_show=true`, i.e. exactly this
/// background run). `WidgetsBinding.exitApplication()` was tried first
/// and reliably crashed -- see the method channel name's sibling doc
/// comment in `flutter_window.cpp` for the full native-side explanation.
/// `dart:io`'s `exit(0)` was tried before that and reliably hung the
/// process instead (unresponsive to `Stop-Process`/`taskkill`, only
/// killable via `Get-CimInstance Win32_Process | Invoke-CimMethod
/// Terminate`) -- consistent with a forced `ExitProcess` racing the
/// native window's own COM/message-loop teardown (`main.cpp`'s
/// `::CoInitializeEx`/`GetMessage` loop) rather than going through it.
/// Posting our own `WM_CLOSE` drives that same teardown the normal way
/// instead of racing or bypassing it.
const _backgroundQuitChannel = MethodChannel('essentials/background_quit');

/// Runs one pass of [BackgroundScheduleService.runDueScheduledEvents],
/// the same class/logic Android's `workmanager` callback already uses
/// (see `background_schedule_service.dart`) -- Windows and Android share
/// the actual "what's due, run it" code, only how each platform triggers
/// it differs. Ends the process when done, success or failure alike --
/// nothing else will ever pump the hidden window's message loop closed
/// (there's no user to click anything), so this process must terminate
/// itself or it would sit around indefinitely as an invisible zombie.
Future<void> runWindowsBackgroundScheduleCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await BackgroundScheduleService().runDueScheduledEvents();
  } catch (_) {
    // Nothing to report to -- there's no UI and no OS-level task-failure
    // signal worth wiring up for a single missed check; the next
    // scheduled run tries again independently, same "transient failures
    // should not need manual intervention" posture as the Android side's
    // retry-via-returning-false.
  } finally {
    await _backgroundQuitChannel.invokeMethod('quit');
  }
}
