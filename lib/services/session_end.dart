import 'package:flutter/services.dart';

/// Windows ending the session - shutdown, restart, sign-out, or an installer
/// asking the app to close - as the runner reports it
/// (windows/runner/flutter_window.cpp).
///
/// The app used to learn nothing about it. Windows ends a process that is
/// still running once its windows have answered, so the download queue, a
/// watch position waiting for its debounced write and the window's last
/// geometry went with it: the app sits in the tray overnight with VODs
/// queued, Windows Update restarts the machine, and nothing is left to
/// resume. The runner now tells Dart and waits, briefly, for it to save.
///
/// Three calls, native to Dart, all with null arguments:
///  * `queryEnd`: Windows is asking whether the session may end
///    (WM_QUERYENDSESSION). Not awaited by the runner; the save starts here
///    so it is under way before it is needed.
///  * `end`: the session is ending (WM_ENDSESSION). The runner waits a few
///    seconds for the reply, because the process can be ended as soon as it
///    has answered.
///  * `cancelled`: something else refused, and the session goes on.
class SessionEnd {
  SessionEnd._();

  static const MethodChannel channel = MethodChannel('streamlink_gui/session');

  /// Runs [onEnding] once per ending session - from the first of `queryEnd`
  /// and `end`, and `end` answers only once it has finished - and
  /// [onCancelled] when the end was called off.
  static void listen({
    required Future<void> Function() onEnding,
    required void Function() onCancelled,
  }) {
    Future<void>? saving;
    Future<void> save() => saving ??= Future.sync(onEnding).catchError((_) {});

    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'queryEnd':
          save();
          return null;
        case 'end':
          await save();
          return true;
        case 'cancelled':
          saving = null;
          onCancelled();
          return null;
      }
      return null;
    });
  }

  static void stopListening() => channel.setMethodCallHandler(null);
}
