#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // When set (from --start-minimized), the first-frame callback skips Show()
  // so the app can boot straight to the tray without the window flashing.
  void SetStartHidden(bool start_hidden) { start_hidden_ = start_hidden; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  void OnChildContentReshown() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Handles single_instance::ActivateMessage(): a second launch asked this
  // instance to come forward.
  void ActivateForSecondInstance();

  // Shows the window the way it should come back: a first show uses the
  // restored placement's command (maximized included), a minimized window is
  // restored, a hidden one shown. Then re-asserts the content view and takes
  // the foreground.
  void BringToFront();

  // Shows the frame for the first time (the first-frame callback, or a later
  // summons when the app started hidden) and puts it back on the restored
  // bounds if showing it moved it. See ApplyInitialPlacement.
  void ShowFirstTime();

  // Handles "setInitialPlacement" on the window channel: moves the still
  // hidden frame to the bounds the Dart side restored, and records how the
  // first show should present it. Returns the resulting window state.
  flutter::EncodableValue ApplyInitialPlacement(
      const flutter::EncodableMap& args);

  // window_placement::DescribeWindow for this window, plus "shown": whether
  // the frame has been on screen yet. A frame that started hidden is not
  // zoomed until its first show, however that show will present it, so its
  // "maximized" says nothing about the session until then.
  flutter::EncodableMap Describe();

  // Windows ending the session (WM_QUERYENDSESSION / WM_ENDSESSION): tells
  // Dart, and for a real end waits a bounded time for it to save, since the
  // process can be ended as soon as WM_ENDSESSION returns. See
  // lib/services/session_end.dart.
  void NotifySession(const char* method);
  void WaitForSessionSave();

  // Native -> Dart session-end notifications ("streamlink_gui/session"). Uses
  // the engine's messenger, so it must be released before flutter_controller_.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      session_channel_;

  // Dart-to-native window geometry ("streamlink_gui/window"): monitors in
  // physical pixels, the restorable window state, the initial placement and
  // a placement-aware show. Uses the engine's messenger, so it must be
  // released before flutter_controller_.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // The bounds the Dart side restored, held until the first show. Windows can
  // defer the DPI change of a hidden window that moved monitors until it is
  // shown, and the WM_DPICHANGED that follows rescales the frame; the first
  // show then puts it back.
  std::optional<RECT> initial_bounds_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Tells Dart about second-launch activations. Uses the engine's messenger,
  // so it must be released before flutter_controller_.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      instance_channel_;

  bool start_hidden_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
