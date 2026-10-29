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
      expect(body(main, 'int LauncherShowCommand('),
          contains('STARTF_USESHOWWINDOW'));
      final asked = body(main, 'bool LauncherAskedNotToActivate(');
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
      final set = win.indexOf('window.SetStartInBackground(\n'
          '      start_hidden || LauncherAskedNotToActivate(launch_show_command));');
      expect(set, isNonNegative);
      expect(set, lessThan(win.indexOf('window.Create(')));
    });

    test('holds the foreground lock from before the window exists', () {
      final create = body(window, 'bool Win32Window::Create(');
      final lock = create.indexOf('BeginBackgroundStart();');
      expect(lock, isNonNegative);
      expect(create.lastIndexOf('if (start_in_background_', lock), isNonNegative,
          reason: 'only for such a launch');
      expect(lock, lessThan(create.indexOf('CreateWindow(')));
      expect(create.indexOf('background_start_over_ = false;'), lessThan(lock),
          reason: "the Destroy() Create starts with ends the old window's start");

      final begin = body(window, 'void Win32Window::BeginBackgroundStart(');
      expect(begin, contains('LockSetForegroundWindow(LSFW_LOCK)'));
      expect(begin, contains('!background_start_over_'),
          reason: 'never once the start is over: nothing would let go of it');
      expect(body(window, 'void Win32Window::EndBackgroundStart('),
          contains('background_start_over_ = true;'));
    });

    test('or from when Dart says the Start minimized setting keeps it hidden',
        () {
      // Only Dart reads the setting. It reached the runner with the initial
      // placement, after window_manager's title bar setup had activated the
      // hidden frame, which on a launch from Explorer took the foreground.
      // Dart now says so before it touches the window (app_startup_test).
      final flutter = read('windows/runner/flutter_window.cpp');
      final onCreate = body(flutter, 'bool FlutterWindow::OnCreate(');
      final handler = onCreate.indexOf('method == "startsHidden"');
      expect(handler, isNonNegative);
      final asked =
          onCreate.indexOf('if (args && GetBool(*args, "hidden")) {', handler);
      expect(asked, isNonNegative);
      expect(onCreate.indexOf('StartHidden();', asked),
          lessThan(onCreate.indexOf('} else if', handler)));

      final start = body(flutter, 'void FlutterWindow::StartHidden(');
      final notShown = start.indexOf('if (HasBeenShown()) {');
      expect(notShown, isNonNegative, reason: 'a shown window stays shown');
      expect(notShown, lessThan(start.indexOf('start_hidden_ = true;')));
      expect(start.indexOf('start_hidden_ = true;'),
          lessThan(start.indexOf('BeginBackgroundStart();')));

      final placement = body(flutter, 'FlutterWindow::ApplyInitialPlacement(');
      expect(placement, contains('StartHidden();'),
          reason: 'the hidden flag there still counts if the early call failed');
      expect(placement, isNot(contains('start_hidden_ = true;')));
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
      final showDecision =
          onCreate.indexOf('ShowFirstTime(/*as_launched=*/true);', frame);
      expect(showDecision, isNonNegative);
      expect(onCreate.indexOf('EndBackgroundStart();', showDecision), isNonNegative,
          reason: 'a window that stays hidden ends it on its first frame');
    });
  });

  group("the launcher's show command", () {
    // Windows applies STARTUPINFO's command only by swapping it in for the
    // process's first ShowWindow, and only for a plain show: the
    // SW_SHOWMAXIMIZED of a window restored maximized was left as it was, so
    // a "Run: Minimized" shortcut or a SW_SHOWNOACTIVATE launcher got a
    // maximized, activated window. The runner applies the command itself.
    final flutter = read('windows/runner/flutter_window.cpp');

    test('is taken from Windows before any show can use it', () {
      // A ShowWindow(SW_HIDE) on the still-hidden window uses the swap up
      // (measured: the next plain show was no longer swapped), so neither a
      // plugin's show nor a later summons from the tray gets it.
      final create = body(window, 'bool Win32Window::Create(');
      final hide = create.indexOf('ShowWindow(window, SW_HIDE);');
      expect(hide, greaterThan(create.indexOf('CreateWindow(')));
      expect(hide, lessThan(create.indexOf('OnCreate()')));

      final main = read('windows/runner/main.cpp');
      final win = body(main, 'int APIENTRY wWinMain(');
      final set =
          win.indexOf('window.SetLaunchShowCommand(launch_show_command);');
      expect(set, isNonNegative);
      expect(set, lessThan(win.indexOf('window.Create(')));
    });

    test('is applied to the first show at launch, on top of the placement', () {
      final launched = body(window, 'void Win32Window::ShowAsLaunched(');
      String branch(String label) {
        final at = launched.indexOf(label);
        expect(at, isNonNegative, reason: label);
        return launched.substring(at, launched.indexOf('break;', at));
      }

      // Minimized, restoring to maximized: only the placement can say both.
      final minimized = branch('case SW_SHOWMINNOACTIVE:');
      expect(launched.indexOf('case SW_MINIMIZE:'),
          lessThan(launched.indexOf('case SW_SHOWMINNOACTIVE:')));
      expect(minimized, contains('placement.showCmd = launch_show_command_;'));
      expect(minimized, contains('placement.flags |= WPF_RESTORETOMAXIMIZED;'));
      expect(minimized,
          contains('SetWindowPlacement(window_handle_, &placement);'));
      expect(minimized,
          isNot(matches(RegExp(r'ShowWindow\([^)]*SW_SHOWMAXIMIZED'))),
          reason: 'the show that opened it maximized and activated');

      // Without activation: maximized only with the lock still held.
      final quiet = branch('case SW_SHOWNA:');
      expect(quiet,
          contains('maximized ? SW_SHOWMAXIMIZED : launch_show_command_'));
      final end = launched.lastIndexOf('EndBackgroundStart();');
      expect(end, greaterThan(launched.indexOf('case SW_SHOWNA:')),
          reason: 'let go after the show, so the show cannot take the '
              'foreground');
      expect(launched.indexOf('EndBackgroundStart();'), end,
          reason: 'and not before it');

      // Anything else: the placement's own show, as before.
      final normal = launched.substring(launched.indexOf('default:'));
      expect(normal.indexOf('Show();'), lessThan(normal.indexOf('return;')));
    });

    test('and only there: a summons shows the window as the user asks', () {
      final onCreate = body(flutter, 'bool FlutterWindow::OnCreate(');
      expect(
          onCreate.indexOf('ShowFirstTime(/*as_launched=*/true);',
              onCreate.indexOf('SetNextFrameCallback(')),
          isNonNegative);
      expect(body(flutter, 'void FlutterWindow::BringToFront('),
          contains('ShowFirstTime(/*as_launched=*/false);'));
      final first = body(flutter, 'void FlutterWindow::ShowFirstTime(');
      expect(first.indexOf('ShowAsLaunched();'),
          lessThan(first.indexOf('Show();')));
      expect(first, contains('!::IsIconic(window)'),
          reason: "a minimized frame's rectangle is not its bounds");
    });

    test('SW_HIDE starts it in the tray, and Dart hears so', () {
      // Windows kept the first show hidden, and the check after the first
      // frame then showed the window anyway and took the foreground.
      final main = read('windows/runner/main.cpp');
      final win = body(main, 'int APIENTRY wWinMain(');
      final hide = win.indexOf('if (launch_show_command == SW_HIDE) {');
      expect(hide, isNonNegative);
      expect(win.indexOf('start_hidden = true;', hide),
          lessThan(win.indexOf('window.SetStartHidden(start_hidden);')));

      final onCreate = body(flutter, 'bool FlutterWindow::OnCreate(');
      final handler = onCreate.indexOf('method == "startsHidden"');
      expect(
          onCreate.substring(handler, onCreate.indexOf('} else if', handler)),
          contains(
              'flutter::EncodableValue(start_hidden_ && !HasBeenShown())'),
          reason: "the runner's answer, which app_startup_test shows wins");
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
