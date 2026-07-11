#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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

  FlutterWindow window(project);
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
