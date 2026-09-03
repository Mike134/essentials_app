#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |suppress_auto_show| is for the hidden background-schedule-check run
  // (see main.cpp): it skips the show-on-first-frame callback (the window
  // must never be shown) and instead wires up kBackgroundQuitChannel, a
  // native quit path that avoids WidgetsBinding.exitApplication()'s
  // hwnd-less ::PostQuitMessage branch -- see flutter_window.cpp's
  // kBackgroundQuitChannel doc comment for why that branch reliably
  // crashed here.
  explicit FlutterWindow(const flutter::DartProject& project,
                        bool suppress_auto_show = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // See the constructor's |suppress_auto_show| doc comment.
  bool suppress_auto_show_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Only set when |suppress_auto_show_| is true. See the constructor's doc
  // comment.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      background_quit_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
