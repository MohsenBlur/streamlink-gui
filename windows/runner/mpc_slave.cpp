#include "mpc_slave.h"

#include <tlhelp32.h>

#include <algorithm>
#include <cerrno>
#include <condition_variable>
#include <cwchar>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

namespace mpc_slave {

namespace {

constexpr wchar_t kSessionClassName[] = L"TwitchStreamlinkGUI.MpcSlave";
constexpr wchar_t kDispatchClassName[] =
    L"TwitchStreamlinkGUI.MpcSlaveDispatch";

// Posted by a worker to the dispatch window: wParam the job, lParam whether
// the player took the message.
constexpr UINT kSendDoneMessage = WM_APP + 1;

// Generous: the player can be seeking a network stream when the message
// arrives. A player that has stopped pumping messages altogether is given up
// on sooner (SMTO_ABORTIFHUNG), one that exits at once (SMTO_ERRORONEXIT).
constexpr UINT kSendTimeoutMs = 5000;

// The largest message the player is believed. CMD_NOWPLAYING, the longest,
// carries a title, an author, a description and a path.
constexpr DWORD kMaxPayloadBytes = 256 * 1024;

// Messages a session holds before Bind. The player sends a handful at
// startup (connect, load state, now playing, play mode).
constexpr size_t kMaxHeld = 32;

// streamlink.exe -> python -> the player is two levels; anything past this is
// not a launch of ours.
constexpr int kMaxAncestry = 8;

bool RegisterClassOnce(const wchar_t* name, WNDPROC procedure) {
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = procedure;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = name;
  return ::RegisterClassExW(&window_class) != 0 ||
         ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

// A message-only window: it has no position on any screen, takes no input and
// is left out of window enumeration and broadcasts. |owner| is stored for the
// window procedure.
HWND CreateMessageWindow(const wchar_t* class_name, WNDPROC procedure,
                         void* owner) {
  if (!RegisterClassOnce(class_name, procedure)) {
    return nullptr;
  }
  HWND window = ::CreateWindowExW(0, class_name, L"", 0, 0, 0, 0, 0,
                                  HWND_MESSAGE, nullptr,
                                  ::GetModuleHandleW(nullptr), nullptr);
  if (window != nullptr) {
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(owner));
  }
  return window;
}

bool CreationTime(HANDLE process, FILETIME* created) {
  FILETIME exited, kernel, user;
  return ::GetProcessTimes(process, created, &exited, &kernel, &user) != 0;
}

bool CreationTimeOf(DWORD pid, FILETIME* created) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  const bool known = CreationTime(process, created);
  ::CloseHandle(process);
  return known;
}

// The process that owns |window|, or 0.
DWORD WindowProcess(HWND window) {
  DWORD pid = 0;
  if (window == nullptr || !::IsWindow(window) ||
      ::GetWindowThreadProcessId(window, &pid) == 0) {
    return 0;
  }
  return pid;
}

}  // namespace

bool IsPlayerNotification(ULONG_PTR command) {
  switch (command) {
    case kConnect:
    case kState:
    case kPlayMode:
    case kNowPlaying:
    case kCurrentPosition:
    case kNotifySeek:
    case kNotifyEndOfStream:
    case kVersion:
    case kDisconnect:
      return true;
    default:
      return false;
  }
}

bool IsHostCommand(ULONG_PTR command) {
  switch (command) {
    case kSetPosition:
    case kGetNowPlaying:
    case kGetCurrentPosition:
    case kCloseApp:
      return true;
    default:
      return false;
  }
}

std::optional<std::wstring> ReadPayload(const COPYDATASTRUCT& data) {
  if (data.cbData == 0) {
    return std::wstring();
  }
  if (data.lpData == nullptr || data.cbData % sizeof(wchar_t) != 0 ||
      data.cbData > kMaxPayloadBytes) {
    return std::nullopt;
  }
  const auto* text = static_cast<const wchar_t*>(data.lpData);
  const size_t capacity = data.cbData / sizeof(wchar_t);
  size_t length = 0;
  while (length < capacity && text[length] != L'\0') {
    ++length;
  }
  return std::wstring(text, length);
}

std::optional<HWND> ParseWindowHandle(const std::wstring& text) {
  if (text.empty() || text.size() > 11) {
    return std::nullopt;
  }
  for (size_t i = 0; i < text.size(); ++i) {
    const wchar_t c = text[i];
    if (!(c >= L'0' && c <= L'9') && !(i == 0 && c == L'-')) {
      return std::nullopt;
    }
  }
  wchar_t* end = nullptr;
  errno = 0;
  const long value = std::wcstol(text.c_str(), &end, 10);
  if (errno == ERANGE || end == text.c_str() || *end != L'\0' || value == 0) {
    return std::nullopt;
  }
  return reinterpret_cast<HWND>(static_cast<INT_PTR>(value));
}

std::wstring FormatWindowHandle(HWND window) {
  return std::to_wstring(
      static_cast<long>(reinterpret_cast<INT_PTR>(window)));
}

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size =
      ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                            static_cast<int>(text.size()), nullptr, 0,
                            nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), &utf8[0], size,
                        nullptr, nullptr);
  return utf8;
}

std::wstring FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), &wide[0], size);
  return wide;
}

bool DescendsFrom(DWORD pid, HANDLE root) {
  const DWORD root_pid = root != nullptr ? ::GetProcessId(root) : 0;
  if (pid == 0 || root_pid == 0) {
    return false;
  }
  if (pid == root_pid) {
    return true;
  }
  FILETIME root_created;
  if (!CreationTime(root, &root_created)) {
    return false;
  }

  std::map<DWORD, DWORD> parents;
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return false;
  }
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  for (BOOL more = ::Process32FirstW(snapshot, &entry); more;
       more = ::Process32NextW(snapshot, &entry)) {
    parents[entry.th32ProcessID] = entry.th32ParentProcessID;
  }
  ::CloseHandle(snapshot);

  DWORD current = pid;
  FILETIME current_created;
  if (!CreationTimeOf(current, &current_created)) {
    return false;
  }
  for (int depth = 0; depth < kMaxAncestry; ++depth) {
    const auto found = parents.find(current);
    if (found == parents.end()) {
      return false;
    }
    const DWORD parent = found->second;
    if (parent == 0 || parent == current) {
      return false;
    }
    // Windows records the parent's id, not the parent: once it exits, the
    // id can be handed to an unrelated process. A real parent is always
    // older than its child, so one that is younger is that reuse. A parent
    // that has already exited cannot be told apart from it, and fails too:
    // streamlink outlives the player it waits on.
    FILETIME parent_created;
    if (parent == root_pid) {
      parent_created = root_created;
    } else if (!CreationTimeOf(parent, &parent_created)) {
      return false;
    }
    if (::CompareFileTime(&parent_created, &current_created) > 0) {
      return false;
    }
    if (parent == root_pid) {
      return true;
    }
    current = parent;
    current_created = parent_created;
  }
  return false;
}

// The worker's queue. Shared with the worker thread, which is detached: a
// send can take kSendTimeoutMs, and the app's window must not wait that long
// to close. Whatever the thread still holds when Sessions is gone is its own
// copy; its last PostMessage goes to a window that no longer exists.
struct Sessions::Queue {
  struct Job {
    uint64_t id;
    int session;
    HWND target;
    HWND from;
    ULONG_PTR command;
    std::wstring payload;
    HWND reply_to;
  };

  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Job> jobs;
  bool started = false;
  bool stopping = false;
};

Sessions::Sessions(EventSink on_event, RejectionSink on_rejection)
    : on_event_(std::move(on_event)),
      on_rejection_(std::move(on_rejection)),
      queue_(std::make_shared<Queue>()) {
  dispatch_window_ =
      CreateMessageWindow(kDispatchClassName, DispatchProc, this);
}

Sessions::~Sessions() {
  CloseAll();
  {
    std::lock_guard<std::mutex> lock(queue_->mutex);
    queue_->stopping = true;
    queue_->jobs.clear();
  }
  queue_->wake.notify_all();
  if (dispatch_window_ != nullptr) {
    ::SetWindowLongPtrW(dispatch_window_, GWLP_USERDATA, 0);
    ::DestroyWindow(dispatch_window_);
    dispatch_window_ = nullptr;
  }
  // Sends still waiting for a reply have nobody to report to.
  std::map<uint64_t, std::pair<int, SendDone>> pending;
  pending.swap(pending_sends_);
  for (auto& entry : pending) {
    entry.second.second(false);
  }
}

int Sessions::Open() {
  auto session = std::make_unique<Session>();
  session->owner = this;
  session->id = next_session_;
  session->window =
      CreateMessageWindow(kSessionClassName, SessionProc, session.get());
  if (session->window == nullptr) {
    return 0;
  }
  ++next_session_;
  const int id = session->id;
  sessions_[id] = std::move(session);
  return id;
}

HWND Sessions::WindowOf(int session) const {
  const auto found = sessions_.find(session);
  return found == sessions_.end() ? nullptr : found->second->window;
}

bool Sessions::Bind(int session_id, DWORD pid) {
  const auto found = sessions_.find(session_id);
  if (found == sessions_.end() || found->second->root != nullptr ||
      pid == 0) {
    return false;
  }
  Session& session = *found->second;
  // SYNCHRONIZE as well, so the handle is a real reference: while it is
  // open the id cannot be given to another process.
  session.root = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, pid);
  if (session.root == nullptr) {
    return false;
  }
  std::vector<Pending> held;
  held.swap(session.held);
  for (const Pending& message : held) {
    // Accept can pass messages on, and nothing it calls comes back here.
    Accept(session, message.command, message.payload, message.sender_pid,
           message.sender_window);
  }
  return true;
}

void Sessions::Send(int session_id, ULONG_PTR command,
                    const std::wstring& payload, SendDone done) {
  const auto found = sessions_.find(session_id);
  if (!IsHostCommand(command) || found == sessions_.end() ||
      found->second->player == nullptr || dispatch_window_ == nullptr) {
    done(false);
    return;
  }
  Session& session = *found->second;
  // The player's window must still be the player's: a destroyed window's
  // handle can be given to another one.
  if (WindowProcess(session.player_window) != session.player_pid) {
    done(false);
    return;
  }

  const uint64_t job = next_job_++;
  pending_sends_[job] = std::make_pair(session_id, std::move(done));
  {
    std::lock_guard<std::mutex> lock(queue_->mutex);
    queue_->jobs.push_back(Queue::Job{job, session_id, session.player_window,
                                      session.window, command, payload,
                                      dispatch_window_});
    if (!queue_->started) {
      queue_->started = true;
      std::thread([queue = queue_]() {
        for (;;) {
          Queue::Job next;
          {
            std::unique_lock<std::mutex> lock(queue->mutex);
            queue->wake.wait(lock, [&queue]() {
              return queue->stopping || !queue->jobs.empty();
            });
            if (queue->stopping) {
              return;
            }
            next = std::move(queue->jobs.front());
            queue->jobs.pop_front();
          }
          // The terminator is part of the message: MPC-BE refuses a payload
          // without one, and MPC-HC reads the string in place.
          COPYDATASTRUCT data = {};
          data.dwData = next.command;
          data.cbData =
              static_cast<DWORD>((next.payload.size() + 1) * sizeof(wchar_t));
          data.lpData = const_cast<wchar_t*>(next.payload.c_str());
          DWORD_PTR handled = 0;
          const LRESULT sent = ::SendMessageTimeoutW(
              next.target, WM_COPYDATA, reinterpret_cast<WPARAM>(next.from),
              reinterpret_cast<LPARAM>(&data),
              SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, kSendTimeoutMs, &handled);
          ::PostMessageW(next.reply_to, kSendDoneMessage,
                         static_cast<WPARAM>(next.id),
                         sent != 0 && handled != 0 ? 1 : 0);
        }
      }).detach();
    }
  }
  queue_->wake.notify_one();
}

void Sessions::Close(int session_id) {
  const auto found = sessions_.find(session_id);
  if (found == sessions_.end()) {
    return;
  }
  std::unique_ptr<Session> session = std::move(found->second);
  sessions_.erase(found);

  {
    std::lock_guard<std::mutex> lock(queue_->mutex);
    queue_->jobs.erase(
        std::remove_if(queue_->jobs.begin(), queue_->jobs.end(),
                       [session_id](const Queue::Job& job) {
                         return job.session == session_id;
                       }),
        queue_->jobs.end());
  }
  std::vector<SendDone> unsent;
  for (auto it = pending_sends_.begin(); it != pending_sends_.end();) {
    if (it->second.first == session_id) {
      unsent.push_back(std::move(it->second.second));
      it = pending_sends_.erase(it);
    } else {
      ++it;
    }
  }

  if (session->window != nullptr) {
    // Detached first: a player blocked sending to this window is released
    // by its destruction, and must find no session behind it.
    ::SetWindowLongPtrW(session->window, GWLP_USERDATA, 0);
    ::DestroyWindow(session->window);
    session->window = nullptr;
  }
  ReleaseHandles(*session);

  for (SendDone& done : unsent) {
    done(false);
  }
}

void Sessions::CloseAll() {
  while (!sessions_.empty()) {
    Close(sessions_.begin()->first);
  }
}

LRESULT CALLBACK Sessions::SessionProc(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam) {
  if (message == WM_COPYDATA) {
    auto* session = reinterpret_cast<Session*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (session == nullptr || session->owner == nullptr || data == nullptr) {
      return FALSE;
    }
    return session->owner->OnCopyData(*session, reinterpret_cast<HWND>(wparam),
                                      *data)
               ? TRUE
               : FALSE;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT CALLBACK Sessions::DispatchProc(HWND window, UINT message,
                                        WPARAM wparam, LPARAM lparam) {
  if (message == kSendDoneMessage) {
    auto* owner =
        reinterpret_cast<Sessions*>(::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (owner != nullptr) {
      owner->OnSendDone(static_cast<uint64_t>(wparam), lparam != 0);
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

bool Sessions::OnCopyData(Session& session, HWND sender,
                          const COPYDATASTRUCT& data) {
  const ULONG_PTR command = data.dwData;
  // wParam is the window the sender says it is: MPC-HC and MPC-BE both pass
  // their main window, the one CMD_CONNECT names.
  const DWORD sender_pid = WindowProcess(sender);
  if (sender_pid == 0) {
    Reject(session, sender_pid, command);
    return false;
  }
  if (!IsPlayerNotification(command)) {
    // The track and playlist lists MPC-HC volunteers after every open, among
    // others: nothing the app reads, so dropped without a word, whoever sent
    // them. Reporting them would read as a stranger at the window.
    return false;
  }
  const std::optional<std::wstring> payload = ReadPayload(data);
  if (!payload) {
    Reject(session, sender_pid, command);
    return false;
  }
  if (session.root == nullptr) {
    if (session.held.size() >= kMaxHeld) {
      Reject(session, sender_pid, command);
      return false;
    }
    session.held.push_back(Pending{command, *payload, sender_pid, sender});
    return true;
  }
  return Accept(session, command, *payload, sender_pid, sender);
}

bool Sessions::Accept(Session& session, ULONG_PTR command,
                      const std::wstring& payload, DWORD sender_pid,
                      HWND sender_window) {
  if (session.player == nullptr) {
    // Not connected yet. The only message that means anything now is the
    // connect, and only from a process this session launched, naming the
    // window it sent from.
    const std::optional<HWND> player_window =
        command == kConnect ? ParseWindowHandle(payload) : std::nullopt;
    if (!player_window || *player_window != sender_window ||
        WindowProcess(*player_window) != sender_pid ||
        !DescendsFrom(sender_pid, session.root)) {
      Reject(session, sender_pid, command);
      return false;
    }
    HANDLE player = ::OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, sender_pid);
    // Checked again now that the process is held: the id was only a number
    // until then, and the window can only still be its if it is the same
    // process.
    if (player == nullptr || WindowProcess(*player_window) != sender_pid) {
      if (player != nullptr) {
        ::CloseHandle(player);
      }
      Reject(session, sender_pid, command);
      return false;
    }
    session.player = player;
    session.player_pid = sender_pid;
    session.player_window = *player_window;
  } else if (sender_pid != session.player_pid ||
             sender_window != session.player_window ||
             (command == kConnect &&
              ParseWindowHandle(payload) != session.player_window)) {
    Reject(session, sender_pid, command);
    return false;
  }
  if (on_event_) {
    on_event_(Event{session.id, command, payload});
  }
  return true;
}

void Sessions::Reject(const Session& session, DWORD sender_pid,
                      ULONG_PTR command) {
  if (on_rejection_) {
    on_rejection_(Rejection{session.id, sender_pid, command});
  }
}

void Sessions::OnSendDone(uint64_t job, bool delivered) {
  const auto found = pending_sends_.find(job);
  if (found == pending_sends_.end()) {
    return;  // its session was closed meanwhile, and already told
  }
  SendDone done = std::move(found->second.second);
  pending_sends_.erase(found);
  done(delivered);
}

void Sessions::ReleaseHandles(Session& session) {
  if (session.player != nullptr) {
    ::CloseHandle(session.player);
    session.player = nullptr;
  }
  if (session.root != nullptr) {
    ::CloseHandle(session.root);
    session.root = nullptr;
  }
}

}  // namespace mpc_slave
