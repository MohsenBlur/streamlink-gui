#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"
#include "window_placement.h"

namespace {

// Native -> Dart only. "activate" is invoked with null arguments, and no reply
// is read, after a second launch has brought this window forward.
constexpr char kInstanceChannelName[] = "streamlink_gui/single_instance";
constexpr char kActivateMethod[] = "activate";

// Dart -> native window geometry; see lib/services/native_window.dart.
constexpr char kWindowChannelName[] = "streamlink_gui/window";

// Native -> Dart, all with null arguments; see lib/services/session_end.dart.
// "queryEnd" when Windows asks whether the session may end (shutdown,
// restart, sign-out, or an installer closing the app), not awaited; "end"
// when it is ending, whose reply is awaited for up to kSessionSaveTimeoutMs;
// "cancelled" when another program refused and the session goes on.
constexpr char kSessionChannelName[] = "streamlink_gui/session";
constexpr char kSessionQueryEndMethod[] = "queryEnd";
constexpr char kSessionEndMethod[] = "end";
constexpr char kSessionCancelledMethod[] = "cancelled";

// Windows lists an app that takes much longer than this to answer as one
// that is preventing shutdown. The save itself takes well under a second.
constexpr ULONGLONG kSessionSaveTimeoutMs = 3000;

// An integer argument, whichever width the codec chose for it.
std::optional<LONG> GetInt(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return std::nullopt;
  }
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<LONG>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<LONG>(*value);
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    return static_cast<LONG>(*value);
  }
  return std::nullopt;
}

bool GetBool(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return false;
  }
  const auto* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Tear down through OnDestroy, never by member destruction. A unique_ptr
  // being destroyed does not clear itself before deleting, so while the
  // implicit teardown ran, flutter_controller_ still pointed at the dying
  // controller and MessageHandler kept routing messages into it (see
  // OnDestroy for why that faults). Destroy() is idempotent, so after
  // main.cpp's explicit teardown this is a no-op.
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // A second launch hands over to this instance rather than starting another
  // (single_instance.h); the channel tells Dart when that happens.
  instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kInstanceChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  single_instance::MarkMainWindow(GetHandle());

  session_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kSessionChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "getMonitors") {
          result->Success(
              flutter::EncodableValue(window_placement::DescribeMonitors()));
        } else if (method == "getPlacement") {
          result->Success(flutter::EncodableValue(
              window_placement::DescribeWindow(GetHandle(), GetChildContent())));
        } else if (method == "startHidden") {
          StartHidden();
          result->Success();
        } else if (method == "setInitialPlacement") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          result->Success(
              ApplyInitialPlacement(args ? *args : flutter::EncodableMap()));
        } else if (method == "show") {
          BringToFront();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Re-assert the content view's visibility before the frame appears:
    // showing only the frame is how the window came up empty. See
    // Win32Window's WM_WINDOWPOSCHANGED handler.
    ShowChildContentIfHidden();

    // --start-minimized (or the Start minimized setting, which the Dart side
    // sends before it sets the window up, see StartHidden): stay hidden, so
    // the window only appears when summoned from the tray (or by a second
    // launch, see ActivateForSecondInstance).
    if (!start_hidden_) {
      ShowFirstTime();
    }
    // Shown, or staying hidden: either way the start is over, and with it
    // the hold on the foreground that kept it in the background.
    EndBackgroundStart();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // No window geometry is saved here: the Dart side owns it (see main.cpp).

  // The channels talk through the engine's messenger, so they go first.
  instance_channel_ = nullptr;
  window_channel_ = nullptr;
  session_channel_ = nullptr;

  if (flutter_controller_) {
    // The engine is about to destroy the view HWND, so stop tracking it first.
    ForgetChildContent();

    // Detach the controller BEFORE destroying it. Tearing the view down sends
    // this window messages (WM_PARENTNOTIFY for the dying child, among
    // others), and MessageHandler routes every message to the controller
    // while one is set. By then the engine has already dropped its view, and
    // FlutterDesktopViewControllerHandleTopLevelWindowProc reaches the engine
    // through that view (view_->GetEngine()), so a message routed in during
    // teardown is a null dereference inside flutter_windows.dll.
    std::unique_ptr<flutter::FlutterViewController> controller =
        std::move(flutter_controller_);
    controller.reset();
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnChildContentReshown() {
  // The engine kept presenting while the view was hidden, and nothing about
  // the view becoming visible asks it for a new frame. Request one so the
  // surface the user now sees is current rather than stale or blank.
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
}

void FlutterWindow::ActivateForSecondInstance() {
  if (GetHandle() == nullptr) {
    return;
  }

  BringToFront();

  // This show bypassed Dart, which keeps its own visibility bookkeeping (the
  // tray state, the live pulse), so tell it.
  if (instance_channel_) {
    instance_channel_->InvokeMethod(kActivateMethod, nullptr);
  }
}

void FlutterWindow::BringToFront() {
  HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }

  if (!HasBeenShown()) {
    // Started hidden: the first appearance is the one the restored placement
    // planned, maximized included. A plain SW_SHOW would bring a window that
    // was saved maximized back at its normal size.
    ShowFirstTime();
  } else if (::IsIconic(window)) {
    // Restore only a minimized window. SW_RESTORE on a maximized one restores
    // it to its normal size, which the previous unconditional SW_SHOW +
    // SW_RESTORE did to every maximized window summoned from the tray.
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }

  // Relaunching is what a user does when the window looks broken, so the
  // content view is re-asserted too: it is the half that went missing in the
  // invisible-window bug, and showing the frame alone would only bring the
  // same empty frame forward.
  ShowChildContentIfHidden();
  ::SetForegroundWindow(window);
}

void FlutterWindow::ShowFirstTime() {
  HWND window = GetHandle();
  Show();
  // A hidden window that moved to a monitor with a different DPI can get its
  // WM_DPICHANGED only now, and that handler rescales the frame by the DPI
  // ratio. Put it back where it was restored; a maximized frame is already
  // where it belongs, and its normal bounds were set while hidden.
  if (initial_bounds_ && window != nullptr && !::IsZoomed(window)) {
    RECT now{};
    ::GetWindowRect(window, &now);
    if (!::EqualRect(&now, &*initial_bounds_)) {
      window_placement::MoveExactly(window, *initial_bounds_);
    }
  }
  initial_bounds_.reset();
}

void FlutterWindow::StartHidden() {
  // Only ever adds hiding, and only to a window not yet on screen:
  // --start-minimized was already read from the command line, and the setting
  // means the same thing.
  if (HasBeenShown()) {
    return;
  }
  start_hidden_ = true;
  // The launch at login (--start-minimized) has held the foreground lock
  // since before the window existed. One hidden by the setting is a launch
  // the user made, from Explorer or the Start menu, so Windows lets it take
  // the foreground - and window_manager's title bar setup, next in line,
  // activates the hidden frame: the foreground went to a window nobody could
  // see, keystrokes included, until the user clicked something.
  BeginBackgroundStart();
}

flutter::EncodableValue FlutterWindow::ApplyInitialPlacement(
    const flutter::EncodableMap& args) {
  HWND window = GetHandle();
  if (window == nullptr) {
    return flutter::EncodableValue();
  }
  const bool maximized = GetBool(args, "maximized");
  const bool hidden = GetBool(args, "hidden");
  const auto left = GetInt(args, "left");
  const auto top = GetInt(args, "top");
  const auto width = GetInt(args, "width");
  const auto height = GetInt(args, "height");

  // The expected order is before the first frame, while the frame is still
  // hidden: the move happens where nobody can see it, and the first frame is
  // laid out at the final size and DPI. If the first frame won the race, the
  // window is already up, and the placement is applied to it directly - a
  // visible move, but to the right place.
  const bool shown = HasBeenShown();

  if (left && top && width && height && *width > 0 && *height > 0) {
    RECT bounds{*left, *top, *left + *width, *top + *height};
    if (shown && ::IsZoomed(window)) {
      ::ShowWindow(window, SW_RESTORE);
    }
    window_placement::MoveExactly(window, bounds);
    if (!shown) {
      initial_bounds_ = bounds;
    }
  }

  SetFirstShowCommand(maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
  if (!shown) {
    // Normally StartHidden has run already; this is in case it failed.
    if (hidden) {
      StartHidden();
    }
  } else if (maximized) {
    ::ShowWindow(window, SW_MAXIMIZE);
  }

  return flutter::EncodableValue(
      window_placement::DescribeWindow(window, GetChildContent()));
}

void FlutterWindow::NotifySession(const char* method) {
  if (session_channel_) {
    session_channel_->InvokeMethod(method, nullptr);
  }
}

void FlutterWindow::WaitForSessionSave() {
  if (!session_channel_) {
    return;
  }
  // Shared with the reply handlers, which can run after this returns if Dart
  // answers late; they must not write to a dead stack frame.
  auto answered = std::make_shared<bool>(false);
  session_channel_->InvokeMethod(
      kSessionEndMethod, nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [answered](const flutter::EncodableValue*) { *answered = true; },
          [answered](const std::string&, const std::string&,
                     const flutter::EncodableValue*) { *answered = true; },
          [answered]() { *answered = true; }));

  // Pump messages while waiting rather than blocking: the reply, the engine's
  // tasks (Dart included) and the window channel the save itself calls all
  // run on this thread's message queue.
  const ULONGLONG deadline = ::GetTickCount64() + kSessionSaveTimeoutMs;
  while (!*answered) {
    const ULONGLONG now = ::GetTickCount64();
    if (now >= deadline) {
      break;
    }
    ::MsgWaitForMultipleObjectsEx(0, nullptr,
                                  static_cast<DWORD>(deadline - now),
                                  QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    MSG msg;
    while (!*answered && ::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        // Not this loop's to consume: put it back for the main loop.
        ::PostQuitMessage(static_cast<int>(msg.wParam));
        return;
      }
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // The runner's own messages come first. No plugin knows them, and the tag
  // must be removed while the window still exists, whatever the plugins do
  // with WM_DESTROY.
  if (single_instance::IsActivateMessage(message)) {
    ActivateForSecondInstance();
    return 0;
  }
  if (message == WM_DESTROY) {
    single_instance::UnmarkMainWindow(hwnd);
  }

  // Windows ending the session. Nothing used to handle it, so the process
  // was ended with whatever had not been written yet - the download queue, a
  // watch position waiting for its write, the window's geometry - lost. Dart
  // starts saving at the query, which is answered at once (and still passes
  // on below, so the default "yes" is unchanged), and the end waits for the
  // save, bounded.
  if (message == WM_QUERYENDSESSION) {
    NotifySession(kSessionQueryEndMethod);
  } else if (message == WM_ENDSESSION) {
    if (wparam) {
      WaitForSessionSave();
    } else {
      NotifySession(kSessionCancelledMethod);
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // The frame outlives the controller during teardown (OnDestroy runs
      // before DestroyWindow), so this cannot assume an engine.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
