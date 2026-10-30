// Unit tests for windows/runner/mpc_slave.cpp - the receiver for MPC-HC's
// /slave API - compiled on their own with the runner's flags (build.ps1).
//
// `flutter test` cannot reach the runner's C++, and the build only proves it
// compiles; these run it. A "player" thread in this process plays MPC-HC's
// side: it connects, reports, answers a position request and a seek the way
// MPC-HC does, and tries what a stranger would - another window, a connect
// naming someone else's window, a malformed payload, a session bound to a
// different process.
#include <windows.h>

#include <cstdio>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "mpc_slave.h"

using namespace mpc_slave;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond)                                                   \
  do {                                                                \
    ++g_checks;                                                       \
    if (!(cond)) {                                                    \
      ++g_failures;                                                   \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
    }                                                                 \
  } while (0)

static void Pump(const std::function<bool()>& until, DWORD timeout_ms = 3000) {
  const ULONGLONG deadline = ::GetTickCount64() + timeout_ms;
  while (!until() && ::GetTickCount64() < deadline) {
    MSG msg;
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessageW(&msg);
    }
    ::MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
  }
}

// ---- the fake player ------------------------------------------------------

constexpr UINT kSay = WM_APP + 10;  // wParam: Say*, the player sends it
struct Say {
  HWND to;
  HWND as;  // the wParam to claim
  ULONG_PTR command;
  std::wstring payload;
  bool raw = false;  // use raw_bytes/raw_size instead of payload
  const void* raw_bytes = nullptr;
  DWORD raw_size = 0;
};

static HWND g_master = nullptr;  // where the player replies
static std::vector<ULONG_PTR> g_player_got;
static double g_player_position = 12.5;

static LRESULT CALLBACK PlayerProc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
  if (m == kSay) {
    auto* say = reinterpret_cast<Say*>(wp);
    COPYDATASTRUCT d = {};
    d.dwData = say->command;
    if (say->raw) {
      d.cbData = say->raw_size;
      d.lpData = const_cast<void*>(say->raw_bytes);
    } else {
      d.cbData = static_cast<DWORD>((say->payload.size() + 1) * sizeof(wchar_t));
      d.lpData = const_cast<wchar_t*>(say->payload.c_str());
    }
    return ::SendMessageW(say->to, WM_COPYDATA, reinterpret_cast<WPARAM>(say->as),
                          reinterpret_cast<LPARAM>(&d));
  }
  if (m == WM_COPYDATA) {
    auto* d = reinterpret_cast<COPYDATASTRUCT*>(lp);
    g_player_got.push_back(d->dwData);
    if (d->dwData == kGetCurrentPosition && g_master) {
      wchar_t buf[32];
      swprintf_s(buf, L"%.3f", g_player_position);
      COPYDATASTRUCT r = {};
      r.dwData = kCurrentPosition;
      r.cbData = static_cast<DWORD>((wcslen(buf) + 1) * sizeof(wchar_t));
      r.lpData = buf;
      ::SendMessageW(g_master, WM_COPYDATA, reinterpret_cast<WPARAM>(w),
                     reinterpret_cast<LPARAM>(&r));
    }
    if (d->dwData == kSetPosition && g_master) {
      g_player_position = _wtof(static_cast<const wchar_t*>(d->lpData));
      wchar_t buf[32];
      swprintf_s(buf, L"%.3f", g_player_position);
      COPYDATASTRUCT r = {};
      r.dwData = kNotifySeek;
      r.cbData = static_cast<DWORD>((wcslen(buf) + 1) * sizeof(wchar_t));
      r.lpData = buf;
      ::SendMessageW(g_master, WM_COPYDATA, reinterpret_cast<WPARAM>(w),
                     reinterpret_cast<LPARAM>(&r));
    }
    return TRUE;
  }
  return ::DefWindowProcW(w, m, wp, lp);
}

struct Player {
  HWND window = nullptr;
  HWND other = nullptr;  // a second window of the same process
  std::thread thread;
  DWORD thread_id = 0;

  void Start() {
    HANDLE ready = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    thread = std::thread([this, ready]() {
      thread_id = ::GetCurrentThreadId();
      WNDCLASSEXW c = {};
      c.cbSize = sizeof(c);
      c.lpfnWndProc = PlayerProc;
      c.hInstance = ::GetModuleHandleW(nullptr);
      c.lpszClassName = L"FakeMpcPlayer";
      ::RegisterClassExW(&c);
      window = ::CreateWindowExW(0, L"FakeMpcPlayer", L"", 0, 0, 0, 0, 0,
                                 HWND_MESSAGE, nullptr, c.hInstance, nullptr);
      other = ::CreateWindowExW(0, L"FakeMpcPlayer", L"", 0, 0, 0, 0, 0,
                                HWND_MESSAGE, nullptr, c.hInstance, nullptr);
      ::SetEvent(ready);
      MSG msg;
      while (::GetMessageW(&msg, nullptr, 0, 0) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
      }
      ::DestroyWindow(window);
      ::DestroyWindow(other);
    });
    ::WaitForSingleObject(ready, 5000);
    ::CloseHandle(ready);
  }

  // Sends from the player thread, while this thread pumps.
  LRESULT SayFrom(Say say) {
    LRESULT result = -1;
    bool done = false;
    std::thread sender([&]() {
      result = ::SendMessageW(window, kSay, reinterpret_cast<WPARAM>(&say), 0);
      done = true;
    });
    Pump([&]() { return done; });
    sender.join();
    return result;
  }

  void Stop() {
    ::PostThreadMessageW(thread_id, WM_QUIT, 0, 0);
    thread.join();
  }
};

// ---- tests ----------------------------------------------------------------

static void TestPayload() {
  COPYDATASTRUCT d = {};
  CHECK(ReadPayload(d).has_value() && ReadPayload(d)->empty());

  const wchar_t text[] = L"12.500";
  d.lpData = const_cast<wchar_t*>(text);
  d.cbData = sizeof(text);
  CHECK(ReadPayload(d) == std::wstring(L"12.500"));

  d.cbData = 3;  // odd
  CHECK(!ReadPayload(d).has_value());

  // No terminator within cbData: the bytes end the string, nothing past them
  // is read.
  d.cbData = 2 * sizeof(wchar_t);
  CHECK(ReadPayload(d) == std::wstring(L"12"));

  const wchar_t embedded[] = L"ab\0cd";
  d.lpData = const_cast<wchar_t*>(embedded);
  d.cbData = sizeof(embedded);
  CHECK(ReadPayload(d) == std::wstring(L"ab"));

  std::vector<wchar_t> huge(300 * 1024, L'x');
  d.lpData = huge.data();
  d.cbData = static_cast<DWORD>(huge.size() * sizeof(wchar_t));
  CHECK(!ReadPayload(d).has_value());

  d.lpData = nullptr;
  d.cbData = 4;
  CHECK(!ReadPayload(d).has_value());
}

static void TestWindowHandles() {
  CHECK(ParseWindowHandle(L"123") ==
        reinterpret_cast<HWND>(static_cast<INT_PTR>(123)));
  CHECK(ParseWindowHandle(L"-5") ==
        reinterpret_cast<HWND>(static_cast<INT_PTR>(-5)));
  CHECK(!ParseWindowHandle(L"").has_value());
  CHECK(!ParseWindowHandle(L"0").has_value());
  CHECK(!ParseWindowHandle(L"12a").has_value());
  CHECK(!ParseWindowHandle(L" 12").has_value());
  CHECK(!ParseWindowHandle(L"1-2").has_value());
  CHECK(!ParseWindowHandle(L"99999999999").has_value());
  CHECK(!ParseWindowHandle(L"0x10").has_value());

  HWND window = ::CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr, nullptr, nullptr);
  CHECK(window != nullptr);
  CHECK(ParseWindowHandle(FormatWindowHandle(window)) == window);
  // What MPC-HC does with it: _ttoi, then IntToPtr.
  CHECK(reinterpret_cast<HWND>(static_cast<INT_PTR>(
            _wtoi(FormatWindowHandle(window).c_str()))) == window);
  ::DestroyWindow(window);

  CHECK(IsPlayerNotification(kConnect) && IsPlayerNotification(kDisconnect) &&
        IsPlayerNotification(kCurrentPosition));
  CHECK(!IsPlayerNotification(kSetPosition) && !IsPlayerNotification(0x6ABE51) &&
        !IsPlayerNotification(0x50000004));
  CHECK(IsHostCommand(kGetCurrentPosition) && IsHostCommand(kSetPosition) &&
        IsHostCommand(kCloseApp) && IsHostCommand(kGetNowPlaying));
  CHECK(!IsHostCommand(0xA0000000) /* CMD_OPENFILE */ &&
        !IsHostCommand(0xA0001000) /* CMD_ADDTOPLAYLIST */ &&
        !IsHostCommand(kConnect));
}

struct Child {
  PROCESS_INFORMATION info = {};
  bool Start(const wchar_t* command_line) {
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    std::wstring line = command_line;
    return ::CreateProcessW(nullptr, &line[0], nullptr, nullptr, FALSE,
                            CREATE_NO_WINDOW, nullptr, nullptr, &si, &info) != 0;
  }
  void End() {
    ::TerminateProcess(info.hProcess, 0);
    ::WaitForSingleObject(info.hProcess, 5000);
    ::CloseHandle(info.hProcess);
    ::CloseHandle(info.hThread);
  }
};

#include <tlhelp32.h>
static DWORD ChildOf(DWORD parent) {
  DWORD found = 0;
  HANDLE snap = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  PROCESSENTRY32W e = {};
  e.dwSize = sizeof(e);
  for (BOOL more = ::Process32FirstW(snap, &e); more; more = ::Process32NextW(snap, &e)) {
    if (e.th32ParentProcessID == parent) found = e.th32ProcessID;
  }
  ::CloseHandle(snap);
  return found;
}

static void TestAncestry() {
  HANDLE self = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                              FALSE, ::GetCurrentProcessId());
  CHECK(DescendsFrom(::GetCurrentProcessId(), self));

  Child ping;
  CHECK(ping.Start(L"C:\\Windows\\System32\\ping.exe -n 6 127.0.0.1"));
  CHECK(DescendsFrom(ping.info.dwProcessId, self));
  CHECK(!DescendsFrom(::GetCurrentProcessId(), ping.info.hProcess));

  // A grandchild, as the player is under streamlink.
  Child cmd;
  CHECK(cmd.Start(L"C:\\Windows\\System32\\cmd.exe /c C:\\Windows\\System32\\ping.exe -n 6 127.0.0.1"));
  DWORD grandchild = 0;
  for (int i = 0; i < 100 && grandchild == 0; ++i) {
    ::Sleep(20);
    grandchild = ChildOf(cmd.info.dwProcessId);
  }
  CHECK(grandchild != 0);
  CHECK(DescendsFrom(grandchild, self));
  CHECK(DescendsFrom(grandchild, cmd.info.hProcess));
  CHECK(!DescendsFrom(grandchild, ping.info.hProcess));
  CHECK(!DescendsFrom(0, self));
  CHECK(!DescendsFrom(grandchild, nullptr));

  cmd.End();
  ping.End();
  ::CloseHandle(self);
}

static void TestSessions() {
  std::vector<Event> events;
  std::vector<Rejection> rejections;
  auto sessions = std::make_unique<Sessions>(
      [&](const Event& e) { events.push_back(e); },
      [&](const Rejection& r) { rejections.push_back(r); });

  Player player;
  player.Start();

  const int id = sessions->Open();
  CHECK(id > 0);
  HWND window = sessions->WindowOf(id);
  CHECK(window != nullptr && ::IsWindow(window));
  // Message-only: no parent on the desktop.
  CHECK(::GetAncestor(window, GA_PARENT) != ::GetDesktopWindow());
  g_master = window;

  // Held before Bind, and judged at Bind.
  const std::wstring me = FormatWindowHandle(player.window);
  CHECK(player.SayFrom({window, player.window, kConnect, me}) == TRUE);
  CHECK(player.SayFrom({window, player.window, kState, L"1"}) == TRUE);
  CHECK(events.empty() && rejections.empty());

  // Sending before a connect is refused.
  bool refused = false;
  sessions->Send(id, kGetCurrentPosition, L"", [&](bool ok) { refused = !ok; });
  CHECK(refused);

  CHECK(sessions->Bind(id, ::GetCurrentProcessId()));
  CHECK(events.size() == 2);
  CHECK(events.size() == 2 && events[0].command == kConnect &&
        events[0].payload == me && events[1].command == kState &&
        events[1].payload == L"1");
  CHECK(!sessions->Bind(id, ::GetCurrentProcessId()));  // once

  // Another window, even of the same process, is not the player.
  events.clear();
  CHECK(player.SayFrom({window, player.other, kPlayMode, L"0"}) == FALSE);
  CHECK(events.empty() && rejections.size() == 1 &&
        rejections.back().command == kPlayMode &&
        rejections.back().sender_pid == ::GetCurrentProcessId());
  // A command the player never sends, or one the app does not read, is
  // dropped without a report; a malformed payload is refused.
  CHECK(player.SayFrom({window, player.window, 0xA0000000, L"C:\\x"}) == FALSE);
  CHECK(player.SayFrom({window, player.window, 0x50000004, L"x|-1"}) == FALSE);
  CHECK(rejections.size() == 1 && events.empty());
  const char odd[3] = {'a', 0, 0};
  Say malformed{window, player.window, kPlayMode, L""};
  malformed.raw = true;
  malformed.raw_bytes = odd;
  malformed.raw_size = 3;
  CHECK(player.SayFrom(malformed) == FALSE);
  // A claimed sender that is no window at all.
  CHECK(player.SayFrom({window, reinterpret_cast<HWND>(static_cast<INT_PTR>(0x7ffe)),
                        kPlayMode, L"0"}) == FALSE);
  CHECK(rejections.size() == 3);
  CHECK(player.SayFrom({window, player.window, kPlayMode, L"0"}) == TRUE);
  CHECK(events.size() == 1 && events[0].command == kPlayMode);

  // A round trip: the reply arrives as an event, then the send reports.
  events.clear();
  int done = -1;
  sessions->Send(id, kGetCurrentPosition, L"", [&](bool ok) { done = ok; });
  Pump([&]() { return done != -1; });
  CHECK(done == 1);
  CHECK(events.size() == 1 && events[0].command == kCurrentPosition &&
        events[0].payload == L"12.500");

  events.clear();
  done = -1;
  sessions->Send(id, kSetPosition, L"600", [&](bool ok) { done = ok; });
  Pump([&]() { return done != -1; });
  CHECK(done == 1);
  CHECK(events.size() == 1 && events[0].command == kNotifySeek &&
        events[0].payload == L"600.000");

  // Not a command the app sends.
  done = -1;
  sessions->Send(id, 0xA0000000 /* CMD_OPENFILE */, L"C:\\x", [&](bool ok) { done = ok; });
  CHECK(done == 0);

  // Close: the window goes, and later messages have no session.
  sessions->Close(id);
  CHECK(!::IsWindow(window));
  CHECK(sessions->WindowOf(id) == nullptr);
  done = -1;
  sessions->Send(id, kGetCurrentPosition, L"", [&](bool ok) { done = ok; });
  CHECK(done == 0);

  // A session bound to another process refuses this one's connect.
  rejections.clear();
  events.clear();
  Child ping;
  CHECK(ping.Start(L"C:\\Windows\\System32\\ping.exe -n 6 127.0.0.1"));
  const int other = sessions->Open();
  HWND other_window = sessions->WindowOf(other);
  CHECK(sessions->Bind(other, ping.info.dwProcessId));
  CHECK(player.SayFrom({other_window, player.window, kConnect, me}) == FALSE);
  CHECK(events.empty() && rejections.size() == 1 &&
        rejections[0].command == kConnect);
  // A connect naming a window other than the sender's.
  const int third = sessions->Open();
  HWND third_window = sessions->WindowOf(third);
  CHECK(sessions->Bind(third, ::GetCurrentProcessId()));
  CHECK(player.SayFrom({third_window, player.window, kConnect,
                        FormatWindowHandle(player.other)}) == FALSE);
  CHECK(player.SayFrom({third_window, player.window, kConnect, L"garbage"}) == FALSE);
  CHECK(events.empty());
  // Messages before a connect are refused once bound.
  CHECK(player.SayFrom({third_window, player.window, kPlayMode, L"0"}) == FALSE);
  CHECK(player.SayFrom({third_window, player.window, kConnect, me}) == TRUE);
  CHECK(events.size() == 1);
  // A second connect naming a different window is refused.
  CHECK(player.SayFrom({third_window, player.window, kConnect,
                        FormatWindowHandle(player.other)}) == FALSE);
  ping.End();

  // Bind to a process that does not exist.
  const int fourth = sessions->Open();
  CHECK(!sessions->Bind(fourth, 0));
  CHECK(!sessions->Bind(fourth, 0xFFFFFFF0));
  CHECK(!sessions->Bind(9999, ::GetCurrentProcessId()));

  // Destroying the lot answers what is outstanding and frees the windows.
  CHECK(::IsWindow(third_window));
  sessions.reset();
  CHECK(!::IsWindow(third_window) && !::IsWindow(other_window));

  g_master = nullptr;
  player.Stop();
}

// Holding many before Bind is bounded.
static void TestHeldLimit() {
  std::vector<Event> events;
  std::vector<Rejection> rejections;
  Sessions sessions([&](const Event& e) { events.push_back(e); },
                    [&](const Rejection& r) { rejections.push_back(r); });
  Player player;
  player.Start();
  const int id = sessions.Open();
  HWND window = sessions.WindowOf(id);
  for (int i = 0; i < 40; ++i) {
    player.SayFrom({window, player.window, kPlayMode, L"0"});
  }
  CHECK(rejections.size() == 8);
  player.Stop();
}

int main() {
  TestPayload();
  TestWindowHandles();
  TestAncestry();
  TestSessions();
  TestHeldLimit();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
