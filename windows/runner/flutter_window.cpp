#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
// Channel the background-schedule-check Dart entrypoint uses to quit
// instead of WidgetsBinding.exitApplication(). That API's platform-channel
// handler (System.exitApplication) never threads an HWND through when
// called this way, so the Windows embedder takes its hwnd-less branch --
// a bare ::PostQuitMessage that skips WM_CLOSE/WM_DESTROY entirely,
// meaning FlutterWindow::OnDestroy() (which resets flutter_controller_)
// never runs before the message loop exits. The engine/view controller
// then gets torn down by ordinary C++ destructor unwind once wWinMain's
// stack-allocated FlutterWindow goes out of scope -- outside the message
// loop, with no engine-shutdown handshake -- which reproduced this
// process's access violation in flutter_windows.dll on effectively every
// background-schedule-check run. Posting our own WM_CLOSE instead drives
// the exact same DefWindowProc -> DestroyWindow -> WM_DESTROY ->
// OnDestroy() path a user closing the window normally takes, which has
// no such crash history.
constexpr char kBackgroundQuitChannel[] = "essentials/background_quit";
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool suppress_auto_show)
    : project_(project), suppress_auto_show_(suppress_auto_show) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (!suppress_auto_show_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      this->Show();
    });

    // Flutter can complete the first frame before the "show window" callback is
    // registered. The following call ensures a frame is pending to ensure the
    // window is shown. It is a no-op if the first frame hasn't completed yet.
    flutter_controller_->ForceRedraw();
  } else {
    // See kBackgroundQuitChannel's doc comment above for why this exists.
    HWND hwnd = GetHandle();
    background_quit_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            flutter_controller_->engine()->messenger(), kBackgroundQuitChannel,
            &flutter::StandardMethodCodec::GetInstance());
    background_quit_channel_->SetMethodCallHandler(
        [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result) {
          if (call.method_name() == "quit") {
            ::PostMessage(hwnd, WM_CLOSE, 0, 0);
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
  }

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
