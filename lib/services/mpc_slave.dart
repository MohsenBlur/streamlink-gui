import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/mpc_slave_protocol.dart';
import '../utils/player_progress.dart';

/// A message the runner passed on from a session's player.
class MpcSlaveEvent {
  const MpcSlaveEvent(this.session, this.command, this.payload);

  final int session;
  final int command;
  final String payload;
}

/// A message the runner refused: not from the player the session launched,
/// or not one a player sends. [pid] is the sender's process, 0 when it could
/// not be told.
class MpcSlaveRejection {
  const MpcSlaveRejection(this.session, this.pid, this.command);

  final int session;
  final int pid;
  final int command;
}

/// A session's control window, in the form `/slave` takes.
class MpcSlaveWindow {
  const MpcSlaveWindow(this.session, this.window);

  final int session;
  final String window;
}

/// The runner's side of MPC-HC's /slave API (windows/runner/mpc_slave.cpp),
/// behind a seam: tests drive [MpcSlaveSession] and the player service with a
/// fake, and no runner.
abstract class MpcSlaveChannel {
  /// A new session's window. Throws when there is none to be had.
  Future<MpcSlaveWindow> open();

  /// Tells the session which process it launched: the player, or the
  /// streamlink that starts it. The runner takes messages only from that
  /// process or one it started.
  Future<bool> bind(int session, int pid);

  /// Sends [command] to the session's connected player; whether it took it.
  Future<bool> send(int session, int command, String payload);

  /// Ends the session and destroys its window.
  Future<void> close(int session);

  Stream<MpcSlaveEvent> get events;
  Stream<MpcSlaveRejection> get rejections;
}

/// [MpcSlaveChannel] over "streamlink_gui/mpc_slave".
class MethodChannelMpcSlave implements MpcSlaveChannel {
  MethodChannelMpcSlave(
      {MethodChannel channel = const MethodChannel('streamlink_gui/mpc_slave')})
      : _channel = channel;

  final MethodChannel _channel;
  final StreamController<MpcSlaveEvent> _events =
      StreamController<MpcSlaveEvent>.broadcast(sync: true);
  final StreamController<MpcSlaveRejection> _rejections =
      StreamController<MpcSlaveRejection>.broadcast(sync: true);
  bool _listening = false;

  @override
  Stream<MpcSlaveEvent> get events => _events.stream;

  @override
  Stream<MpcSlaveRejection> get rejections => _rejections.stream;

  // Installed on first use rather than at construction: the service that
  // owns this is built before anything plays, in tests that never bind a
  // messenger among them.
  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments;
    if (args is! Map) return null;
    final session = args['session'];
    final command = args['command'];
    if (session is! int || command is! int) return null;
    switch (call.method) {
      case 'event':
        final payload = args['payload'];
        _events.add(
            MpcSlaveEvent(session, command, payload is String ? payload : ''));
      case 'rejected':
        final pid = args['pid'];
        _rejections
            .add(MpcSlaveRejection(session, pid is int ? pid : 0, command));
    }
    return null;
  }

  @override
  Future<MpcSlaveWindow> open() async {
    _listen();
    final reply = await _channel.invokeMapMethod<String, Object?>('open');
    final session = reply?['session'];
    final window = reply?['window'];
    if (session is! int || window is! String || window.isEmpty) {
      throw StateError('the runner gave no control window');
    }
    return MpcSlaveWindow(session, window);
  }

  @override
  Future<bool> bind(int session, int pid) async =>
      await _channel.invokeMethod<bool>(
          'bind', {'session': session, 'pid': pid}) ??
      false;

  @override
  Future<bool> send(int session, int command, String payload) async {
    try {
      return await _channel.invokeMethod<bool>('send', {
            'session': session,
            'command': command,
            'payload': payload,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> close(int session) async {
    try {
      await _channel.invokeMethod<void>('close', {'session': session});
    } on PlatformException {
      // Nothing left to close.
    } on MissingPluginException {
      // Likewise.
    }
  }
}

/// One player session over /slave: what the player has said, and the two
/// questions the app asks it.
class MpcSlaveSession {
  MpcSlaveSession._(this._channel, this.id, this.window) {
    _eventSubscription = _channel.events.listen((event) {
      if (event.session == id) _onEvent(event);
    });
    _rejectionSubscription = _channel.rejections.listen((rejection) {
      if (rejection.session == id) onRejected?.call(rejection);
    });
  }

  /// Opens a session on [channel]. Throws when the runner has no window to
  /// give, as [MpcSlaveChannel.open] does.
  static Future<MpcSlaveSession> open(MpcSlaveChannel channel) async {
    final window = await channel.open();
    return MpcSlaveSession._(channel, window.session, window.window);
  }

  final MpcSlaveChannel _channel;
  final int id;

  /// What the player is launched with: `/slave <window>`.
  final String window;

  final MpcSlaveState state = MpcSlaveState();

  /// Every message the player sent, after it has been folded into [state].
  void Function(MpcSlaveEvent event)? onEvent;

  /// Every message the runner refused for this session.
  void Function(MpcSlaveRejection rejection)? onRejected;

  late final StreamSubscription<MpcSlaveEvent> _eventSubscription;
  late final StreamSubscription<MpcSlaveRejection> _rejectionSubscription;
  Completer<double?>? _positionAnswer;
  Completer<double?>? _seekAnswer;
  bool _closed = false;

  /// The player has connected and not yet said it is closing.
  bool get connected =>
      state.connected && !state.disconnected && !_closed;

  Future<bool> bind(int pid) => _channel.bind(id, pid);

  void _onEvent(MpcSlaveEvent event) {
    state.apply(event.command, event.payload);
    if (event.command == MpcCommand.currentPosition) {
      _complete(_positionAnswer, parseMpcSeconds(event.payload));
    } else if (event.command == MpcCommand.notifySeek) {
      _complete(_seekAnswer, parseMpcSeconds(event.payload));
    }
    onEvent?.call(event);
  }

  static void _complete(Completer<double?>? answer, double? value) {
    if (answer != null && !answer.isCompleted) answer.complete(value);
  }

  /// One poll: asks where the player is and folds the answer into a status.
  ///
  /// Null when there is no player to ask or it did not take the question:
  /// no facts this tick, as a failed HTTP poll was. A player that has not
  /// loaded anything is not asked - it would not answer - and reads as
  /// stopped, as the web interface reported it.
  Future<PlayerStatus?> poll(
      {Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (!connected) return null;
    if (state.loadState != MpcLoadState.loaded) return state.status(null);
    // The answer arrives as its own message, which can reach Dart before or
    // after the send's result does; the completer takes either order.
    final answer = _positionAnswer = Completer<double?>();
    try {
      if (!await _channel.send(id, MpcCommand.getCurrentPosition, '')) {
        return null;
      }
      final position =
          await answer.future.timeout(timeout, onTimeout: () => null);
      return connected ? state.status(position) : null;
    } finally {
      if (identical(_positionAnswer, answer)) _positionAnswer = null;
    }
  }

  /// Asks the player to jump to [seconds]; true once it reports the seek.
  ///
  /// The player takes the command whether or not it can act on it - nothing
  /// loaded, say - so taking it is not the acknowledgement. The seek
  /// notification it sends once it has moved is. MPC-HC can defer a seek
  /// that follows another closely, hence the wait.
  Future<bool> seek(int seconds,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (!connected) return false;
    final answer = _seekAnswer = Completer<double?>();
    try {
      if (!await _channel.send(
          id, MpcCommand.setPosition, mpcSetPositionPayload(seconds))) {
        return false;
      }
      return await answer.future.timeout(timeout, onTimeout: () => null) !=
          null;
    } finally {
      if (identical(_seekAnswer, answer)) _seekAnswer = null;
    }
  }

  /// Ends the session: the runner destroys the window and stops listening
  /// for this player. Questions still waiting get no answer.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _complete(_positionAnswer, null);
    _complete(_seekAnswer, null);
    final closing = _channel.close(id);
    await _eventSubscription.cancel();
    await _rejectionSubscription.cancel();
    await closing;
  }
}
