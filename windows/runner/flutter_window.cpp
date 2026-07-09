#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  HWND hwnd = GetHandle();
  WINDOWPLACEMENT wp = { sizeof(wp) };
  if (GetWindowPlacement(hwnd, &wp)) {
    HKEY hKey;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\TwitchStreamlinkGUI", 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hKey, nullptr) == ERROR_SUCCESS) {
      DWORD x = wp.rcNormalPosition.left;
      DWORD y = wp.rcNormalPosition.top;
      DWORD w = wp.rcNormalPosition.right - wp.rcNormalPosition.left;
      DWORD h = wp.rcNormalPosition.bottom - wp.rcNormalPosition.top;
      
      RegSetValueExW(hKey, L"WindowX", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&x), sizeof(x));
      RegSetValueExW(hKey, L"WindowY", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&y), sizeof(y));
      RegSetValueExW(hKey, L"WindowW", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&w), sizeof(w));
      RegSetValueExW(hKey, L"WindowH", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&h), sizeof(h));
      
      RegCloseKey(hKey);
    }
  }

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
