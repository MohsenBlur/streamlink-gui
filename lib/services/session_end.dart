import 'dart:async';

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
///
/// An answered `end` is not always the end of the process. The Restart
/// Manager closing apps for an installer sends WM_ENDSESSION(TRUE) with
/// ENDSESSION_CLOSEAPP, and only asks: an app that does not quit goes on
/// running. Nothing told Dart so, and that session's hold stayed for the
/// rest of the run - the download queue frozen as it was at that moment,
/// saved like that by every later write, and a later real shutdown handed
/// the finished save instead of a fresh one. A process still running
/// [defaultSurvivalGrace] after answering was not ended, and goes back to
/// normal.
class SessionEnd {
  SessionEnd._();

  static const MethodChannel channel = MethodChannel('streamlink_gui/session');

  /// How long after answering `end` a process that is still running is
  /// taken to have outlived the session end. Windows ends the process as soon
  /// as it has answered; half a minute is far past that, and short of
  /// anything a user carrying on in the app would notice.
  static const Duration defaultSurvivalGrace = Duration(seconds: 30);

  static Timer? _survival;

  /// Runs [onEnding] once per ending session - from the first of `queryEnd`
  /// and `end`, and `end` answers only once it has finished - and
  /// [onCancelled] when the end was called off. [onSurvived] (default:
  /// [onCancelled]) runs when this process is still running [survivalGrace]
  /// after answering `end`.
  static void listen({
    required Future<void> Function() onEnding,
    required void Function() onCancelled,
    void Function()? onSurvived,
    Duration survivalGrace = defaultSurvivalGrace,
  }) {
    _cancelSurvival();
    Future<void>? saving;
    Future<void> save() => saving ??= Future.sync(onEnding).catchError((_) {});

    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'queryEnd':
          // Another session end inside the grace: the hold stays for it.
          _cancelSurvival();
          save();
          return null;
        case 'end':
          _cancelSurvival();
          await save();
          // Answered: whatever comes next is a new session end, with a save
          // of its own.
          saving = null;
          _survival = Timer(survivalGrace, () {
            _survival = null;
            (onSurvived ?? onCancelled)();
          });
          return true;
        case 'cancelled':
          _cancelSurvival();
          saving = null;
          onCancelled();
          return null;
      }
      return null;
    });
  }

  static void stopListening() {
    _cancelSurvival();
    channel.setMethodCallHandler(null);
  }

  static void _cancelSurvival() {
    _survival?.cancel();
    _survival = null;
  }
}
