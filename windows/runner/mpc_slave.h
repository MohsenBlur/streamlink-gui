#ifndef RUNNER_MPC_SLAVE_H_
#define RUNNER_MPC_SLAVE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// MPC-HC's /slave control API, as the app's host side of it.
//
// The app used to start MPC-HC with /webport and drive it over its web
// interface, which has no authentication: for as long as a VOD played, any
// program on the machine - and any web page, with a plain GET - could list
// folders through it, make the player open a UNC path (handing the account's
// NTLM hash to whoever serves it) or send it commands. /slave is MPC-HC's
// documented local API instead: the player is started with "/slave <hwnd>"
// and talks to that window with WM_COPYDATA, and the host answers the same
// way. Window messages never leave the desktop, browsers cannot send them, and
// UIPI keeps lower-integrity processes from sending this one at all - nothing
// here relaxes that.
//
// The command ids and payloads are MPC-HC's src/mpc-hc/MpcApi.h (2.8.4,
// a19e22c0a); MPC-BE's mpcapi.h uses the same ids and formats. Every payload is
// a null-terminated UTF-16 string. MPC-HC sends each message with SendMessage
// and wParam set to its main window.
//
// One message-only window per player session: the window is the address the
// player is given, so which session a message belongs to is never inferred. A
// session accepts messages only from the process it launched (the player, or
// a descendant of streamlink, which starts the player itself), and only from
// the window that process connected with - see Sessions::Accept.
namespace mpc_slave {

// Player -> host.
constexpr ULONG_PTR kConnect = 0x50000000;
constexpr ULONG_PTR kState = 0x50000001;
constexpr ULONG_PTR kPlayMode = 0x50000002;
constexpr ULONG_PTR kNowPlaying = 0x50000003;
constexpr ULONG_PTR kCurrentPosition = 0x50000007;
constexpr ULONG_PTR kNotifySeek = 0x50000008;
constexpr ULONG_PTR kNotifyEndOfStream = 0x50000009;
constexpr ULONG_PTR kVersion = 0x5000000A;
constexpr ULONG_PTR kDisconnect = 0x5000000B;

// Host -> player.
constexpr ULONG_PTR kSetPosition = 0xA0002000;
constexpr ULONG_PTR kGetNowPlaying = 0xA0003002;
constexpr ULONG_PTR kGetCurrentPosition = 0xA0003004;
constexpr ULONG_PTR kCloseApp = 0xA0004006;

// The player's notifications a session passes on. Anything else - the track
// and playlist lists, the newer integer channel's companions - is dropped.
bool IsPlayerNotification(ULONG_PTR command);

// The commands the app may send. Not CMD_OPENFILE or CMD_ADDTOPLAYLIST: the
// app never asks the player to open anything over this channel.
bool IsHostCommand(ULONG_PTR command);

// The string a WM_COPYDATA carries: UTF-16 up to the first null within
// cbData. nullopt when it is not one - an odd byte count, or larger than any
// message the player sends. A missing terminator is tolerated (the bytes end
// the string), since the length is known; reading past cbData never happens.
std::optional<std::wstring> ReadPayload(const COPYDATASTRUCT& data);

// CMD_CONNECT's parameter: the player's main window, in decimal ("%d" of
// PtrToInt). nullopt for anything else.
std::optional<HWND> ParseWindowHandle(const std::wstring& text);

// |window| as /slave takes it: decimal, as MPC-HC reads it back with _ttoi.
// Window handles are 32-bit values on 64-bit Windows too.
std::wstring FormatWindowHandle(HWND window);

std::string ToUtf8(const std::wstring& text);
std::wstring FromUtf8(const std::string& text);

// Whether process |pid| is |root| or was started, directly or further down,
// by it. Each parent is checked to have been created before its child, so a
// process whose parent died and whose parent's id was reused by an unrelated
// process cannot pass. |root| must be a handle the caller holds open, which
// keeps its id from being reused while the check runs.
bool DescendsFrom(DWORD pid, HANDLE root);

// A message a session passed on.
struct Event {
  int session;
  ULONG_PTR command;
  std::wstring payload;
};

// A message a session refused, and who sent it (0 when that could not be
// told).
struct Rejection {
  int session;
  DWORD sender_pid;
  ULONG_PTR command;
};

// The open sessions, on the thread that creates this object - the runner's
// platform thread. Every method must be called on it, and the callbacks run on
// it.
class Sessions {
 public:
  using EventSink = std::function<void(const Event&)>;
  using RejectionSink = std::function<void(const Rejection&)>;
  using SendDone = std::function<void(bool delivered)>;

  Sessions(EventSink on_event, RejectionSink on_rejection);
  ~Sessions();

  Sessions(const Sessions&) = delete;
  Sessions& operator=(const Sessions&) = delete;

  // A new session's window, which the player is launched with ("/slave
  // <window>"). Returns the session's id, or 0 if no window could be made.
  int Open();

  // The window Open made for |session|, or nullptr.
  HWND WindowOf(int session) const;

  // Records the process the session launched: the player itself, or the
  // streamlink that starts it. Until then messages are held, not judged; the
  // player can connect before the launcher has been told its own child's id.
  // False if the process could not be opened (it has already gone) or the
  // session is unknown.
  bool Bind(int session, DWORD pid);

  // Sends |command| to the session's player, from a worker thread: the player
  // handles a WM_COPYDATA on its UI thread, and a seek on a network stream
  // can hold that for seconds - which a send from this thread would hold the
  // app's UI for. |done| runs on this thread with whether the player took the
  // message; at once, with false, when there is no connected player to send
  // to or the command is not one the app sends.
  void Send(int session, ULONG_PTR command, const std::wstring& payload,
            SendDone done);

  // Ends |session|: its window is destroyed, its handles closed, its unsent
  // commands dropped and their |done| called with false.
  void Close(int session);

  // Close for every session.
  void CloseAll();

 private:
  struct Pending {
    ULONG_PTR command;
    std::wstring payload;
    DWORD sender_pid;
    HWND sender_window;
  };

  struct Session {
    Sessions* owner = nullptr;
    int id = 0;
    HWND window = nullptr;
    // The process the session launched, held open so its id stays its own.
    HANDLE root = nullptr;
    // The connected player, held open for the same reason.
    HANDLE player = nullptr;
    DWORD player_pid = 0;
    HWND player_window = nullptr;
    // Messages that arrived before Bind.
    std::vector<Pending> held;
  };

  struct Queue;

  static LRESULT CALLBACK SessionProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  static LRESULT CALLBACK DispatchProc(HWND window, UINT message,
                                       WPARAM wparam, LPARAM lparam);

  // A WM_COPYDATA to |session|'s window.
  bool OnCopyData(Session& session, HWND sender, const COPYDATASTRUCT& data);

  // Judges one message from |sender_window|, which |sender_pid| owned when it
  // arrived: passes it on, or refuses it. Returns which.
  bool Accept(Session& session, ULONG_PTR command, const std::wstring& payload,
              DWORD sender_pid, HWND sender_window);

  void Reject(const Session& session, DWORD sender_pid, ULONG_PTR command);

  // A worker's report that a send finished.
  void OnSendDone(uint64_t job, bool delivered);

  static void ReleaseHandles(Session& session);

  EventSink on_event_;
  RejectionSink on_rejection_;
  std::map<int, std::unique_ptr<Session>> sessions_;
  int next_session_ = 1;

  // Receives the workers' completions; message-only, like the sessions.
  HWND dispatch_window_ = nullptr;
  std::shared_ptr<Queue> queue_;
  std::map<uint64_t, std::pair<int, SendDone>> pending_sends_;
  uint64_t next_job_ = 1;
};

}  // namespace mpc_slave

#endif  // RUNNER_MPC_SLAVE_H_
