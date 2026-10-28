import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the runner's window takes the foreground and keyboard focus.
///
/// The runner's C++ has no tests of its own, and what this guards is a
/// launch measured with a foreground sampler, which no test here can run;
/// so the source is read, as the other runner checks do.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');
  final window = read('windows/runner/win32_window.cpp');

  String body(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNonNegative, reason: signature);
    return source.substring(start, source.indexOf('\n}\n', start));
  }

  /// Calls of [function] itself, not of one whose name ends the same way
  /// (LockSetForegroundWindow is not SetForegroundWindow).
  int callsOf(String source, String function) =>
      RegExp('(?<![A-Za-z_])$function\\(').allMatches(source).length;

  test('creating the window does not activate it', () {
    // SetFocus activates the top-level window of what it focuses. Called
    // unconditionally as the hidden frame was created, it made that frame
    // the foreground window at every launch Windows let take it, the
    // -NoActivate harness launch and launch at login included.
    final setChild = body(window, 'void Win32Window::SetChildContent(');
    final guard = setChild.indexOf('if (GetActiveWindow() == window_handle_) {');
    expect(guard, isNonNegative, reason: 'the focus call must be guarded');
    expect(callsOf(setChild, 'SetFocus'), 1);
    expect(setChild.indexOf('SetFocus(child_content_);'), greaterThan(guard));
  });

  test("activating it still hands the keyboard focus to the engine's view", () {
    final handler = body(window, 'Win32Window::MessageHandler(');
    final activate = handler.indexOf('case WM_ACTIVATE:');
    expect(activate, isNonNegative);
    expect(
        handler.substring(activate, handler.indexOf('return 0;', activate)),
        contains('SetFocus(child_content_);'));
  });

  group('a launch that must stay in the background', () {
    // With that call guarded, window_manager's title bar setup took the
    // foreground next: its SetWindowPos has no SWP_NOACTIVATE, which
    // activates a hidden top-level window too. Such a launch holds the
    // foreground lock while the window is hidden.
    test('is one started hidden or asked to show without activation', () {
      final main = read('windows/runner/main.cpp');
      final asked = body(main, 'bool LauncherAskedNotToActivate(');
      expect(asked, contains('STARTF_USESHOWWINDOW'));
      for (final command in [
        'SW_HIDE',
        'SW_SHOWNOACTIVATE',
        'SW_MINIMIZE',
        'SW_SHOWMINNOACTIVE',
        'SW_SHOWNA',
      ]) {
        expect(asked, contains('case $command:'));
      }
      // A normal launch needs its right to the foreground for its first
      // show, and the lock gives that up.
      for (final command in ['SW_SHOWNORMAL', 'SW_SHOW:', 'SW_SHOWDEFAULT', 'SW_SHOWMAXIMIZED']) {
        expect(asked, isNot(contains(command)));
      }

      final win = body(main, 'int APIENTRY wWinMain(');
      final set = win.indexOf(
          'window.SetStartInBackground(start_hidden || LauncherAskedNotToActivate());');
      expect(set, isNonNegative);
      expect(set, lessThan(win.indexOf('window.Create(')));
    });

    test('holds the foreground lock from before the window exists', () {
      final create = body(window, 'bool Win32Window::Create(');
      final lock = create.indexOf('LockSetForegroundWindow(LSFW_LOCK)');
      expect(lock, isNonNegative);
      expect(create.lastIndexOf('if (start_in_background_', lock), isNonNegative,
          reason: 'only for such a launch');
      expect(lock, lessThan(create.indexOf('CreateWindow(')));
    });

    test('until it is shown, its first frame passes hidden, or it is destroyed', () {
      final end = body(window, 'void Win32Window::EndBackgroundStart(');
      expect(end, contains('LockSetForegroundWindow(LSFW_UNLOCK);'));

      final show = body(window, 'bool Win32Window::Show(');
      expect(show.indexOf('EndBackgroundStart();'), isNonNegative);
      expect(show.indexOf('EndBackgroundStart();'), lessThan(show.indexOf('ShowWindow(')),
          reason: 'a second launch brings it forward right after this show');
      expect(body(window, 'void Win32Window::Destroy('), contains('EndBackgroundStart();'));

      final flutter = read('windows/runner/flutter_window.cpp');
      final onCreate = body(flutter, 'bool FlutterWindow::OnCreate(');
      final frame = onCreate.indexOf('SetNextFrameCallback(');
      final showDecision = onCreate.indexOf('ShowFirstTime();', frame);
      expect(showDecision, isNonNegative);
      expect(onCreate.indexOf('EndBackgroundStart();', showDecision), isNonNegative,
          reason: 'a window that stays hidden ends it on its first frame');
    });
  });

  test('nothing else in the frame takes the focus or the foreground', () {
    // The deliberate ones live in FlutterWindow::BringToFront, for a
    // second launch or the tray asking for the window.
    expect(callsOf(window, 'SetFocus'), 2,
        reason: 'SetChildContent, guarded, and WM_ACTIVATE');
    expect(callsOf(window, 'SetForegroundWindow'), 0);
    expect(callsOf(window, 'SetActiveWindow'), 0);
  });
}
