#include "single_instance.h"

namespace single_instance {

namespace {

constexpr wchar_t kMainWindowProperty[] = L"TwitchStreamlinkGUI.MainWindow";
constexpr wchar_t kActivateMessageName[] = L"TwitchStreamlinkGUI.Activate";

// EnumWindows callback: stops at the first top-level window carrying the tag.
// EnumWindows includes hidden windows, which matters here: resting in the
// tray, the main window is hidden, not minimized.
BOOL CALLBACK FindTaggedWindow(HWND window, LPARAM found) {
  if (::GetPropW(window, kMainWindowProperty) == nullptr) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(found) = window;
  return FALSE;
}

}  // namespace

UINT ActivateMessage() {
  static const UINT message = ::RegisterWindowMessageW(kActivateMessageName);
  return message;
}

bool IsActivateMessage(UINT message) {
  return message != 0 && message == ActivateMessage();
}

void MarkMainWindow(HWND window) {
  ::SetPropW(window, kMainWindowProperty, reinterpret_cast<HANDLE>(1));
  if (ActivateMessage() != 0) {
    ::ChangeWindowMessageFilterEx(window, ActivateMessage(), MSGFLT_ALLOW,
                                  nullptr);
  }
}

void UnmarkMainWindow(HWND window) {
  ::RemovePropW(window, kMainWindowProperty);
}

bool ActivateRunningInstance() {
  if (ActivateMessage() == 0) {
    return false;
  }

  HWND window = nullptr;
  ::EnumWindows(FindTaggedWindow, reinterpret_cast<LPARAM>(&window));
  if (window == nullptr) {
    return false;
  }

  // The user just started this process, so Windows lets it bring a window to
  // the foreground. Hand that right to the running instance, which raises
  // itself when it handles the message; without it, the foreground lock
  // would only flash its taskbar button.
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  ::AllowSetForegroundWindow(process_id);

  return ::PostMessageW(window, ActivateMessage(), 0, 0) != FALSE;
}

}  // namespace single_instance
