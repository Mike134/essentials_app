import 'dart:ui' show AppExitType;

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

/// Runs one pass of [BackgroundScheduleService.runDueScheduledEvents],
/// the same class/logic Android's `workmanager` callback already uses
/// (see `background_schedule_service.dart`) -- Windows and Android share
/// the actual "what's due, run it" code, only how each platform triggers
/// it differs. Ends the process when done, success or failure alike --
/// nothing else will ever pump the hidden window's message loop closed
/// (there's no user to click anything), so this process must terminate
/// itself or it would sit around indefinitely as an invisible zombie.
///
/// **Deliberately `WidgetsBinding.instance.exitApplication(AppExitType
/// .required)`, not `dart:io`'s `exit(0)`.** The first version used
/// `exit(0)` and was confirmed, empirically, to intermittently leave the
/// process hung indefinitely (near-zero CPU, unresponsive to
/// `Stop-Process`/`taskkill`, only killable via `Get-CimInstance
/// Win32_Process | Invoke-CimMethod Terminate`) -- consistent with a
/// forced `ExitProcess` racing the native window's own COM/message-loop
/// teardown (`main.cpp`'s `::CoInitializeEx`/`GetMessage` loop) rather
/// than going through it. `exitApplication` instead calls into the
/// Windows embedder's own `System.exitApplication` platform-channel
/// handler (confirmed by reading the engine source,
/// `shell/platform/windows/platform_handler.cc`), which posts a real
/// quit through the same native path a user closing the window normally
/// takes -- `main.cpp`'s `GetMessage` loop ends on its own, followed by
/// its own `::CoUninitialize()`/`return EXIT_SUCCESS`. Re-verified stable
/// across repeated runs after this switch, where `exit(0)` was
/// reproducibly flaky.
Future<void> runWindowsBackgroundScheduleCheck() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  try {
    await BackgroundScheduleService().runDueScheduledEvents();
  } catch (_) {
    // Nothing to report to -- there's no UI and no OS-level task-failure
    // signal worth wiring up for a single missed check; the next
    // scheduled run tries again independently, same "transient failures
    // should not need manual intervention" posture as the Android side's
    // retry-via-returning-false.
  } finally {
    await binding.exitApplication(AppExitType.required);
  }
}
