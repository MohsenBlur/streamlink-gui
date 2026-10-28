#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"

namespace {

// Native -> Dart only. "activate" is invoked with null arguments, and no reply
// is read, after a second launch has brought this window forward.
constexpr char kInstanceChannelName[] = "streamlink_gui/single_instance";
constexpr char kActivateMethod[] = "activate";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Tear down through OnDestroy, never by member destruction. A unique_ptr
  // being destroyed does not clear itself before deleting, so while the
  // implicit teardown ran, flutter_controller_ still pointed at the dying
  // controller and MessageHandler kept routing messages into it (see
  // OnDestroy for why that faults). Destroy() is idempotent, so after
  // main.cpp's explicit teardown this is a no-op.
  Destroy();
}

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

  // A second launch hands over to this instance rather than starting another
  // (single_instance.h); the channel tells Dart when that happens.
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kInstanceChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  single_instance::MarkMainWindow(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Re-assert the content view's visibility before the frame appears:
    // showing only the frame is how the window came up empty. See
    // Win32Window's WM_WINDOWPOSCHANGED handler.
    ShowChildContentIfHidden();

    // --start-minimized: stay hidden; the Dart side also skips its show(), so
    // the window only appears when summoned from the tray (or by a second
    // launch, see ActivateForSecondInstance).
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // No window geometry is saved here: the Dart side owns it (see main.cpp).

  // The channel talks through the engine's messenger, so it goes first.
  instance_channel_ = nullptr;

  if (flutter_controller_) {
    // The engine is about to destroy the view HWND, so stop tracking it first.
    ForgetChildContent();

    // Detach the controller BEFORE destroying it. Tearing the view down sends
    // this window messages (WM_PARENTNOTIFY for the dying child, among
    // others), and MessageHandler routes every message to the controller
    // while one is set. By then the engine has already dropped its view, and
    // FlutterDesktopViewControllerHandleTopLevelWindowProc reaches the engine
    // through that view (view_->GetEngine()), so a message routed in during
    // teardown is a null dereference inside flutter_windows.dll.
    std::unique_ptr<flutter::FlutterViewController> controller =
        std::move(flutter_controller_);
    controller.reset();
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnChildContentReshown() {
  // The engine kept presenting while the view was hidden, and nothing about
  // the view becoming visible asks it for a new frame. Request one so the
  // surface the user now sees is current rather than stale or blank.
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
}

void FlutterWindow::ActivateForSecondInstance() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }

  // Restore only a minimized window. SW_RESTORE on a maximized one restores
  // it to its normal size, which the previous unconditional SW_SHOW +
  // SW_RESTORE did to every maximized window summoned from the tray.
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }

  // Relaunching is what a user does when the window looks broken, so the
  // content view is re-asserted too: it is the half that went missing in the
  // invisible-window bug, and showing the frame alone would only bring the
  // same empty frame forward.
  ShowChildContentIfHidden();
  ::SetForegroundWindow(window);

  // This show bypassed Dart, which keeps its own visibility bookkeeping (the
  // tray state, the live pulse), so tell it.
  if (instance_channel_) {
    instance_channel_->InvokeMethod(kActivateMethod, nullptr);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The runner's own messages come first. No plugin knows them, and the tag
  // must be removed while the window still exists, whatever the plugins do
  // with WM_DESTROY.
  if (single_instance::IsActivateMessage(message)) {
    ActivateForSecondInstance();
    return 0;
  }
  if (message == WM_DESTROY) {
    single_instance::UnmarkMainWindow(hwnd);
  }

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
      // The frame outlives the controller during teardown (OnDestroy runs
      // before DestroyWindow), so this cannot assume an engine.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
