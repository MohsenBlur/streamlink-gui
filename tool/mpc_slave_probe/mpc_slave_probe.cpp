// A forensic instrument, not part of the app: drives a real MPC-HC through
// windows/runner/mpc_slave.cpp - the runner's own receiver, compiled with its
// flags (build.ps1) - and prints every message the PLAYER sends, which is the
// layer the progress tracker consumes.
//
//   mpc_slave_probe.exe --cmd-file <UTF-8 file holding the command line;
//                                   {WINDOW} becomes the session window>
//                       [--seek-at S --seek-to T] [--run-secs N]
//                       [--close-after-eof] [--close-at S]
//
// The command line is launched and bound as the session's process, so it can
// be the player itself or streamlink with the player in --player-args, as the
// app launches either. A position is asked for every second. Run it through
// hidden_desktop.ps1 (and give MPC-HC a portable mpc-hc64.ini, muted) to keep
// it off the user's screens and settings.
//
// Measured with it on MPC-HC 2.8.4 (K-Lite), 2026-10-30:
//   - /start on a local file is honoured; a CMD_SETPOSITION of 60 answers
//     CMD_NOTIFYSEEK "60.000" and the next position reads 60.011.
//   - At the end of a file: CMD_PLAYMODE 1 (paused), CMD_NOTIFYENDOFSTREAM,
//     and the position stays at the duration.
//   - An HLS source that dies mid-play (dying_hls.py): the player drains its
//     buffer at normal speed, then sends CMD_PLAYMODE 1 and
//     CMD_NOTIFYENDOFSTREAM and the position jumps to the full duration -
//     the 2.7.4 web-interface behaviour, now announced.
//   - CMD_NOWPLAYING is repeated every second while a file plays.
//   - CMD_CLOSEAPP: load state 3, play state 2, load state 0,
//     CMD_DISCONNECT, exit code 0.
#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <string>

#include "mpc_slave.h"

using namespace mpc_slave;

static ULONGLONG g_start = 0;
static double Now() { return (::GetTickCount64() - g_start) / 1000.0; }

static const char* Name(ULONG_PTR c) {
  switch (c) {
    case kConnect: return "CONNECT";
    case kState: return "STATE";
    case kPlayMode: return "PLAYMODE";
    case kNowPlaying: return "NOWPLAYING";
    case kCurrentPosition: return "CURRENTPOSITION";
    case kNotifySeek: return "NOTIFYSEEK";
    case kNotifyEndOfStream: return "NOTIFYENDOFSTREAM";
    case kVersion: return "VERSION";
    case kDisconnect: return "DISCONNECT";
    default: return "?";
  }
}

static std::wstring ReadCommandFile(const wchar_t* path) {
  FILE* f = nullptr;
  if (_wfopen_s(&f, path, L"rb") != 0 || f == nullptr) return std::wstring();
  std::string bytes;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) bytes.append(buf, n);
  std::fclose(f);
  while (!bytes.empty() && (bytes.back() == 10 || bytes.back() == 13)) {
    bytes.pop_back();
  }
  return FromUtf8(bytes);
}

int wmain(int argc, wchar_t** argv) {
  g_start = ::GetTickCount64();
  std::wstring cmd;
  double seek_at = -1, seek_to = 0, run_secs = 60, close_at = -1;
  bool close_after_eof = false;
  for (int i = 1; i < argc; ++i) {
    std::wstring a = argv[i];
    if (a == L"--cmd-file" && i + 1 < argc) cmd = ReadCommandFile(argv[++i]);
    else if (a == L"--seek-at" && i + 1 < argc) seek_at = _wtof(argv[++i]);
    else if (a == L"--seek-to" && i + 1 < argc) seek_to = _wtof(argv[++i]);
    else if (a == L"--run-secs" && i + 1 < argc) run_secs = _wtof(argv[++i]);
    else if (a == L"--close-at" && i + 1 < argc) close_at = _wtof(argv[++i]);
    else if (a == L"--close-after-eof") close_after_eof = true;
  }
  if (cmd.empty()) {
    std::printf("no --cmd-file\n");
    return 2;
  }

  HWND player = nullptr;
  double eof_at = -1;
  int rejections = 0;
  Sessions sessions(
      [&](const Event& e) {
        std::printf("[%7.2f] EVENT %-17s '%s'\n", Now(), Name(e.command),
                    ToUtf8(e.payload).c_str());
        if (e.command == kConnect) {
          player = *ParseWindowHandle(e.payload);
          RECT r{};
          ::GetWindowRect(player, &r);
          DWORD ppid = 0;
          ::GetWindowThreadProcessId(player, &ppid);
          std::printf("          player pid %lu, window rect (%ld,%ld)-(%ld,%ld)\n",
                      ppid, r.left, r.top, r.right, r.bottom);
        }
        if (e.command == kNotifyEndOfStream && eof_at < 0) eof_at = Now();
        std::fflush(stdout);
      },
      [&](const Rejection& r) {
        ++rejections;
        std::printf("[%7.2f] REJECTED cmd=0x%llx pid=%lu\n", Now(),
                    static_cast<unsigned long long>(r.command), r.sender_pid);
        std::fflush(stdout);
      });

  const int id = sessions.Open();
  const std::wstring window = FormatWindowHandle(sessions.WindowOf(id));
  size_t at;
  while ((at = cmd.find(L"{WINDOW}")) != std::wstring::npos) {
    cmd.replace(at, 8, window);
  }
  std::printf("[%7.2f] session %d window %s\n", Now(), id, ToUtf8(window).c_str());
  std::printf("[%7.2f] launching: %s\n", Now(), ToUtf8(cmd).c_str());

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_SHOWNOACTIVATE;
  PROCESS_INFORMATION pi{};
  HWND foreground_before = ::GetForegroundWindow();
  if (!::CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    std::printf("CreateProcess failed %lu\n", ::GetLastError());
    return 1;
  }
  std::printf("[%7.2f] pid %lu, bind=%d\n", Now(), pi.dwProcessId,
              sessions.Bind(id, pi.dwProcessId) ? 1 : 0);
  std::fflush(stdout);

  double next_poll = 1.0;
  bool seeked = false, closing = false;
  while (true) {
    MSG msg;
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    if (::WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) {
      DWORD code = 0;
      ::GetExitCodeProcess(pi.hProcess, &code);
      std::printf("[%7.2f] launched process exited, code %lu\n", Now(), code);
      break;
    }
    const double t = Now();
    HWND fg = ::GetForegroundWindow();
    if (fg != foreground_before) {
      DWORD fpid = 0;
      ::GetWindowThreadProcessId(fg, &fpid);
      wchar_t cls[128] = L"";
      ::GetClassNameW(fg, cls, 128);
      std::printf("[%7.2f] FOREGROUND CHANGED to pid %lu class %s\n", t, fpid,
                  ToUtf8(cls).c_str());
      foreground_before = fg;
    }
    if (t >= next_poll && !closing) {
      next_poll = t + 1.0;
      sessions.Send(id, kGetCurrentPosition, L"", [](bool ok) {
        if (!ok) std::printf("[%7.2f] poll not taken\n", Now());
      });
    }
    if (seek_at >= 0 && !seeked && t >= seek_at) {
      seeked = true;
      wchar_t buf[32];
      swprintf_s(buf, L"%.0f", seek_to);
      std::printf("[%7.2f] SETPOSITION %ls\n", t, buf);
      sessions.Send(id, kSetPosition, buf, [](bool ok) {
        std::printf("[%7.2f] SETPOSITION taken=%d\n", Now(), ok ? 1 : 0);
      });
    }
    const bool close_now = (close_after_eof && eof_at >= 0 && t >= eof_at + 3) ||
                           (close_at >= 0 && t >= close_at) || t >= run_secs;
    if (close_now && !closing) {
      closing = true;
      std::printf("[%7.2f] CLOSEAPP\n", t);
      sessions.Send(id, kCloseApp, L"", [](bool ok) {
        std::printf("[%7.2f] CLOSEAPP taken=%d\n", Now(), ok ? 1 : 0);
      });
    }
    if (closing && t >= run_secs + 15) {
      std::printf("[%7.2f] still running; terminating\n", t);
      ::TerminateProcess(pi.hProcess, 9);
    }
    ::MsgWaitForMultipleObjects(1, &pi.hProcess, FALSE, 20, QS_ALLINPUT);
  }
  const ULONGLONG until = ::GetTickCount64() + 500;
  while (::GetTickCount64() < until) {
    MSG msg;
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) ::DispatchMessageW(&msg);
    ::Sleep(10);
  }
  sessions.Close(id);
  std::printf("[%7.2f] session closed, a session window left=%d, rejections=%d\n",
              Now(),
              ::FindWindowExW(HWND_MESSAGE, nullptr, L"TwitchStreamlinkGUI.MpcSlave",
                              nullptr) != nullptr ? 1 : 0,
              rejections);
  ::CloseHandle(pi.hProcess);
  ::CloseHandle(pi.hThread);
  return 0;
}
