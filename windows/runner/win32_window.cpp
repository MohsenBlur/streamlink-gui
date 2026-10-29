#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  // Before the window exists: see SetStartInBackground. A new window is a
  // new start (the Destroy above ended any earlier one).
  background_start_over_ = false;
  if (start_in_background_) {
    BeginBackgroundStart();
  }

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // Uses up the launcher's show command now, while the window is hidden and
  // this changes nothing: Windows hands it to the process's first ShowWindow
  // instead of that call's own command, whichever call that is. See
  // SetLaunchShowCommand for why the runner applies it itself.
  ShowWindow(window, SW_HIDE);

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  EndBackgroundStart();
  return ShowWindow(window_handle_, first_show_command_);
}

void Win32Window::ShowAsLaunched() {
  const bool maximized = first_show_command_ == SW_SHOWMAXIMIZED;
  switch (launch_show_command_) {
    case SW_MINIMIZE:
    case SW_SHOWMINIMIZED:
    case SW_SHOWMINNOACTIVE: {
      // Minimized, as asked. A window restored maximized comes back from the
      // taskbar maximized, which only the placement can say: a minimizing
      // ShowWindow restores to the normal size. Asking ShowWindow for
      // SW_SHOWMAXIMIZED instead, as Show() does, is how a "Run: Minimized"
      // shortcut used to open the window maximized and activated.
      WINDOWPLACEMENT placement{};
      placement.length = sizeof(placement);
      if (maximized && GetWindowPlacement(window_handle_, &placement)) {
        placement.showCmd = launch_show_command_;
        placement.flags |= WPF_RESTORETOMAXIMIZED;
        SetWindowPlacement(window_handle_, &placement);
      } else {
        ShowWindow(window_handle_, launch_show_command_);
      }
      break;
    }
    case SW_SHOWNOACTIVATE:
    case SW_SHOWNA:
      // Shown without activation. No show command maximizes without
      // activating, so a maximized window is shown while the foreground lock
      // is still held (SetStartInBackground): the activation stays inside
      // this thread, and the user's app keeps the foreground.
      ShowWindow(window_handle_,
                 maximized ? SW_SHOWMAXIMIZED : launch_show_command_);
      break;
    case SW_SHOWMAXIMIZED:
      // "Run: Maximized", which Windows' own substitution used to apply.
      ShowWindow(window_handle_, SW_SHOWMAXIMIZED);
      break;
    default:
      // No command, or one that means a normal show (SW_SHOWNORMAL,
      // SW_SHOW, SW_SHOWDEFAULT, SW_RESTORE): the restored placement's.
      Show();
      return;
  }
  // After the show, not before: a lock let go first would let the show take
  // the foreground.
  EndBackgroundStart();
}

void Win32Window::BeginBackgroundStart() {
  if (!background_start_over_ && !holds_foreground_lock_) {
    holds_foreground_lock_ = LockSetForegroundWindow(LSFW_LOCK) != FALSE;
  }
}

void Win32Window::EndBackgroundStart() {
  if (holds_foreground_lock_) {
    LockSetForegroundWindow(LSFW_UNLOCK);
    holds_foreground_lock_ = false;
  }
  background_start_over_ = true;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    // Every activation hands the keyboard focus to the engine's view, the
    // one place it belongs. This is what focuses the view at startup too:
    // SetChildContent no longer does, so as not to activate the frame.
    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    // The runner, not the engine, has the last word on whether the content is
    // visible. Installed launches were caught with this frame shown and the
    // FLUTTERVIEW child's WS_VISIBLE clear, for good: the engine kept
    // rendering into a view nobody could see, and only a manual ShowWindow on
    // the child brought the app back. It happened when window_manager showed
    // and moved the frame across monitors before the first frame, and what
    // clears the flag was never pinned down, so rather than guess, re-assert
    // it whenever the frame is shown, moved or resized.
    //
    // Both messages are needed: WM_SHOWWINDOW is not sent for SW_SHOWNORMAL
    // (which Show() uses), while WM_WINDOWPOSCHANGED also covers the moves
    // and DPI resizes that follow a show. Neither is consumed here:
    // DefWindowProc turns WM_WINDOWPOSCHANGED into WM_SIZE and WM_MOVE.
    case WM_SHOWWINDOW:
      if (wparam) {
        ShowChildContentIfHidden();
      }
      break;

    case WM_WINDOWPOSCHANGED:
      if (IsWindowVisible(hwnd)) {
        has_been_shown_ = true;
        ShowChildContentIfHidden();
      }
      break;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();
  EndBackgroundStart();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  // The engine creates its view WS_VISIBLE, but nothing guarantees the flag
  // survives startup (see the WM_WINDOWPOSCHANGED handler), so set it here
  // too. The frame is still hidden at this point, so this cannot flash.
  ShowChildContentIfHidden();

  // Only into a frame that is already the active window. SetFocus activates
  // the top-level window of whatever it focuses, and this runs as the window
  // is created, still hidden: the stock template's unconditional call made
  // the hidden frame the active window - and, whenever Windows let this
  // process take the foreground, the foreground window, taken from the
  // user's own app at every launch, however it was asked to show (see
  // SetStartInBackground for the rest of that). The view gets the focus when
  // the frame is activated instead, by the WM_ACTIVATE handler: on the first
  // show of a normal launch, or on the user's first click into a window
  // shown without activation.
  if (GetActiveWindow() == window_handle_) {
    SetFocus(child_content_);
  }
}

bool Win32Window::ShowChildContentIfHidden() {
  if (child_content_ == nullptr) {
    return false;
  }
  // The content's OWN flag, not IsWindowVisible: that also reports false
  // whenever the frame is hidden, which is exactly the case during
  // WM_SHOWWINDOW, so it cannot tell a hidden child from a hidden parent.
  if ((GetWindowLongPtr(child_content_, GWL_STYLE) & WS_VISIBLE) != 0) {
    return false;
  }
  // SW_SHOWNA: this can run during a background move or resize, and showing
  // the content must never activate the frame or steal focus.
  ShowWindow(child_content_, SW_SHOWNA);
  OnChildContentReshown();
  return true;
}

void Win32Window::ForgetChildContent() {
  child_content_ = nullptr;
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::OnChildContentReshown() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
