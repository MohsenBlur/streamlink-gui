#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Re-assert the content view's visibility before the frame appears:
    // showing only the frame is how the window came up empty. See
    // Win32Window's WM_WINDOWPOSCHANGED handler.
    ShowChildContentIfHidden();

    // --start-minimized: stay hidden; the Dart side also skips its show(), so
    // the window only appears when summoned from the tray (or by a second
    // instance's FindWindow+ShowWindow).
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
      // The frame outlives the controller during teardown (OnDestroy runs
      // before DestroyWindow), so this cannot assume an engine.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
