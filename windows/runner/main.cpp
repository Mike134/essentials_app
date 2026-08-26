#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Essentials v2 Phase 5 build order step 8 -- a Windows Scheduled Task
  // launches this exact exe with this one flag to run due
  // hourly/daily/weekly scripts in the background, without Mike having
  // the app open. There is no headless Flutter engine on Windows the way
  // Android's workmanager gives one (confirmed via a real spike -- see
  // claude/essentials-v2-phase5-design.md's step 8 write-up: flutter_js
  // transitively needs dart:ui, unavailable outside a real Flutter
  // engine) -- so this still creates a real window and engine, exactly
  // like a normal launch, then hides it immediately below rather than
  // skipping window creation. The Dart side (see main.dart) checks for
  // this same flag and calls exit(0) once the background check
  // completes, instead of ever calling runApp().
  const bool isBackgroundScheduleCheck =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--background-schedule-check") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"essentials_app", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (isBackgroundScheduleCheck) {
    // Create() already shows the window (SW_SHOWNORMAL) before returning
    // -- hide it right back immediately rather than editing win32_window
    // .cpp's own Create() to skip that step, so this stays a minimal,
    // additive change to otherwise-untouched Flutter-generated
    // boilerplate. A brief flash is possible but has not been observed
    // in practice; not worth more invasive surgery on generated code for
    // a scheduled background task nobody is watching happen.
    ::ShowWindow(window.GetHandle(), SW_HIDE);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
