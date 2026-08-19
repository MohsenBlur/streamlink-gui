#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Ensures the helper processes this app spawns (streamlink, yt-dlp, ffmpeg, the
// media player) cannot outlive it, even if the app crashes or is killed.
//
// This replaces a PowerShell watchdog that polled every second for the parent
// PID and then killed its process tree. That approach had three problems: it
// could not distinguish the self-updater from an orphan and so killed the
// updater mid-swap, it was vulnerable to PID reuse, and it could not be stopped.
// A job object makes the cleanup an OS guarantee instead of a polling race.
//
// JOB_OBJECT_LIMIT_BREAKAWAY_OK lets updater.exe deliberately escape the job so
// it survives our exit; see EnsureOutsideJob in win32_updater/main.cpp.
void AssignSelfToKillOnCloseJob() {
  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    return;
  }

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;

  if (!::SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
      !::AssignProcessToJobObject(job, ::GetCurrentProcess())) {
    // Nested jobs without breakaway rights, or an unexpected policy: fall back
    // to no supervision rather than failing to start.
    ::CloseHandle(job);
    return;
  }

  // The handle is intentionally not closed. Closing the last handle to the job
  // is exactly what terminates its members, so it must stay open for the
  // lifetime of the process; the OS closes it on exit, which is the trigger.
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Enforce single instance via named Win32 Mutex
  HANDLE hMutex = ::CreateMutexW(nullptr, TRUE, L"Local\\TwitchStreamlinkGUIUniqueMutexName");
  if (hMutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND hwnd = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (hwnd != nullptr) {
      ::ShowWindow(hwnd, SW_SHOW);
      ::ShowWindow(hwnd, SW_RESTORE);
      ::SetForegroundWindow(hwnd);
    }
    ::CloseHandle(hMutex);
    return EXIT_SUCCESS;
  }

  // Supervise our helper processes so none of them can outlive us. Done after
  // the single-instance check so a second, immediately-exiting instance does
  // not create a job at all.
  AssignSelfToKillOnCloseJob();

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

  // Autostart passes --start-minimized: suppress the first-frame Show() so
  // the app boots straight to the tray without the window flashing.
  bool start_hidden = false;
  for (const std::string& arg : command_line_arguments) {
    if (arg == "--start-minimized") {
      start_hidden = true;
      break;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  int x = 10;
  int y = 10;
  int width = 1280;
  int height = 720;
  
  HKEY hKey;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\TwitchStreamlinkGUI", 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
    DWORD dwType = REG_DWORD;
    DWORD dwSize = sizeof(DWORD);
    DWORD dwVal = 0;
    
    if (RegQueryValueExW(hKey, L"WindowX", nullptr, &dwType, reinterpret_cast<LPBYTE>(&dwVal), &dwSize) == ERROR_SUCCESS) {
      x = static_cast<int>(dwVal);
    }
    if (RegQueryValueExW(hKey, L"WindowY", nullptr, &dwType, reinterpret_cast<LPBYTE>(&dwVal), &dwSize) == ERROR_SUCCESS) {
      y = static_cast<int>(dwVal);
    }
    if (RegQueryValueExW(hKey, L"WindowW", nullptr, &dwType, reinterpret_cast<LPBYTE>(&dwVal), &dwSize) == ERROR_SUCCESS) {
      width = static_cast<int>(dwVal);
    }
    if (RegQueryValueExW(hKey, L"WindowH", nullptr, &dwType, reinterpret_cast<LPBYTE>(&dwVal), &dwSize) == ERROR_SUCCESS) {
      height = static_cast<int>(dwVal);
    }
    
    RegCloseKey(hKey);
  }

  // This pre-Flutter positioning happens before the Dart-side geometry
  // sanitizer can run, so apply the same guard here: if the saved rectangle
  // touches no live monitor (undocked laptop, changed layout), fall back to
  // the defaults instead of materializing the window off-screen.
  RECT probe = {x, y, x + width, y + height};
  if (::MonitorFromRect(&probe, MONITOR_DEFAULTTONULL) == nullptr) {
    x = 10;
    y = 10;
  }

  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);
  Win32Window::Point origin(x, y);
  Win32Window::Size size(width, height);
  if (!window.Create(L"streamlink_gui", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (hMutex != nullptr) {
    ::CloseHandle(hMutex);
  }
  return EXIT_SUCCESS;
}
