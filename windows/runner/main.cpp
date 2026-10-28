#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance.h"
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
    // Hand over to the running instance and leave. It brings itself forward,
    // content view included, and tells Dart; see single_instance.h for why it
    // is found by a property rather than by window class.
    single_instance::ActivateRunningInstance();
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

  // Always created at the template defaults, hidden until the first frame.
  // Geometry has one owner, the Dart side (settings.windowX/Y/W/H, sanitized
  // by lib/utils/window_bounds.dart). This used to restore a second, native
  // copy from HKCU\Software\TwitchStreamlinkGUI first, which only added one
  // more geometry change before the first frame, the startup race behind the
  // invisible-window bug. It was also wrong: it saved physical pixels and
  // restored them as logical ones, so Create() scaled them by the monitor DPI
  // again and the window grew by that factor on every launch, while the
  // off-screen guard checked the rectangle before that scaling.
  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"streamlink_gui", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Tear the window down here, explicitly, while COM is still initialized.
  //
  // Quitting from Dart (windowManager.destroy()) is a bare PostQuitMessage:
  // it ends the loop above without destroying the window, so the engine and
  // every plugin used to be torn down by destructors when this function
  // returned, after CoUninitialize. That is wrong twice over. The engine
  // releases COM objects (DirectManipulation, among others) into an apartment
  // that no longer exists, and the destructor path routed the teardown's own
  // window messages into the half-destroyed view controller (see
  // FlutterWindow::OnDestroy). The second one is the recurring exit crash:
  // every quit through this path faulted in flutter_windows.dll at +0x1d7b0,
  // the offset in the crash log, inside a window procedure (exit status
  // 0xC000041D, an exception during a user callback). Destroy() runs the same
  // ordered teardown as a real close: engine and plugins first, then the HWND.
  window.Destroy();

  ::CoUninitialize();
  if (hMutex != nullptr) {
    ::CloseHandle(hMutex);
  }
  return EXIT_SUCCESS;
}
