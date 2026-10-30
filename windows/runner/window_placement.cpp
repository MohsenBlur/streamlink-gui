#include "window_placement.h"

#include <flutter_windows.h>

#include <cctype>
#include <string>

namespace window_placement {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue Int(LONG value) {
  return EncodableValue(static_cast<int32_t>(value));
}

void PutRect(EncodableMap& map, const char* prefix, const RECT& rect) {
  const std::string p(prefix);
  // "left" for the bare rectangle, "workLeft" for a prefixed one.
  auto key = [&p](const char* name) {
    if (p.empty()) {
      return std::string(name);
    }
    std::string field(name);
    field[0] = static_cast<char>(toupper(field[0]));
    return p + field;
  };
  map[EncodableValue(key("left"))] = Int(rect.left);
  map[EncodableValue(key("top"))] = Int(rect.top);
  map[EncodableValue(key("width"))] = Int(rect.right - rect.left);
  map[EncodableValue(key("height"))] = Int(rect.bottom - rect.top);
}

std::string Narrow(const wchar_t* wide) {
  if (wide == nullptr || *wide == L'\0') {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (length <= 1) {
    return std::string();
  }
  std::string narrow(length - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, narrow.data(), length, nullptr,
                        nullptr);
  return narrow;
}

BOOL CALLBACK AddMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM list) {
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return TRUE;
  }
  EncodableMap entry;
  entry[EncodableValue("name")] = EncodableValue(Narrow(info.szDevice));
  PutRect(entry, "", info.rcMonitor);
  PutRect(entry, "work", info.rcWork);
  entry[EncodableValue("dpi")] =
      Int(static_cast<LONG>(FlutterDesktopGetDpiForMonitor(monitor)));
  entry[EncodableValue("primary")] =
      EncodableValue((info.dwFlags & MONITORINFOF_PRIMARY) != 0);
  reinterpret_cast<EncodableList*>(list)->push_back(EncodableValue(entry));
  return TRUE;
}

}  // namespace

EncodableList DescribeMonitors() {
  EncodableList monitors;
  ::EnumDisplayMonitors(nullptr, nullptr, AddMonitor,
                        reinterpret_cast<LPARAM>(&monitors));
  return monitors;
}

EncodableMap DescribeWindow(HWND window, HWND content) {
  EncodableMap state;
  if (window == nullptr) {
    return state;
  }
  const bool minimized = ::IsIconic(window) != FALSE;
  const bool maximized = ::IsZoomed(window) != FALSE;

  RECT normal{};
  if (minimized || maximized) {
    // The rectangle it restores to. rcNormalPosition is in workspace
    // coordinates, which are offset from screen coordinates by the taskbar
    // (or any appbar) on the top or left of the monitor that rectangle is
    // on. That is the NORMAL rectangle's monitor, not the window's: a window
    // maximized or minimized on one monitor can restore to another, and
    // converting with its current monitor's work area put the restore
    // rectangle off by the wrong taskbar - or by one that monitor does not
    // have. The rectangle is still in workspace coordinates when its
    // monitor is looked up, but those differ from the screen by no more than
    // a taskbar's thickness, which only a rectangle split almost evenly
    // between two monitors could notice.
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    ::GetWindowPlacement(window, &placement);
    normal = placement.rcNormalPosition;
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (::GetMonitorInfoW(::MonitorFromRect(&normal, MONITOR_DEFAULTTONEAREST),
                          &info)) {
      ::OffsetRect(&normal, info.rcWork.left - info.rcMonitor.left,
                   info.rcWork.top - info.rcMonitor.top);
    }
  } else {
    // The live frame, which also covers a window snapped to half a screen:
    // rcNormalPosition still holds the size it had before the snap.
    ::GetWindowRect(window, &normal);
  }
  PutRect(state, "", normal);
  state[EncodableValue("maximized")] = EncodableValue(maximized);
  state[EncodableValue("minimized")] = EncodableValue(minimized);
  state[EncodableValue("visible")] =
      EncodableValue(::IsWindowVisible(window) != FALSE);
  // The content's OWN flag, not IsWindowVisible: that is false whenever the
  // frame is hidden, so every report made before the first show (the startup
  // placement, a window starting in the tray) read "content=false" - the
  // invisible-window bug's signature - on a healthy window. The flag is what
  // that bug cleared; with the frame shown, the two agree.
  state[EncodableValue("contentVisible")] = EncodableValue(
      content != nullptr &&
      (::GetWindowLongPtr(content, GWL_STYLE) & WS_VISIBLE) != 0);
  state[EncodableValue("dpi")] =
      Int(static_cast<LONG>(::GetDpiForWindow(window)));

  MONITORINFOEXW monitor{};
  monitor.cbSize = sizeof(monitor);
  if (::GetMonitorInfoW(::MonitorFromRect(&normal, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
    state[EncodableValue("monitor")] =
        EncodableValue(Narrow(monitor.szDevice));
    PutRect(state, "monitor", monitor.rcMonitor);
  }
  return state;
}

bool MoveExactly(HWND window, const RECT& bounds) {
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  for (int attempt = 0; attempt < 3; ++attempt) {
    ::SetWindowPos(window, nullptr, bounds.left, bounds.top, width, height,
                   SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
    RECT now{};
    ::GetWindowRect(window, &now);
    if (::EqualRect(&now, &bounds)) {
      return true;
    }
  }
  return false;
}

}  // namespace window_placement
